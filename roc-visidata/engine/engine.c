/*
 * The engine: Roc plugins that VisiData runs from their source.
 *
 * VisiData hands a `.roc` file to roc_vd_load, which compiles it here (through
 * libroc_embed, built from the Roc compiler) and then calls its entrypoints
 * through the interpreter. Editing the file and reloading is the whole loop.
 *
 * The plugin's effects come from platform/host.c, included below: the same
 * hosted functions a compiled plugin would link against, so the two kinds of
 * plugin are the same program run two ways.
 */

#define ROC_VD_EMBEDDED 1
#include "../platform/host.c"

#include "roc_embed.h"
#include "roc_vd_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    void *program;      /* what libroc_embed compiled */
    int kind;
    int handle;

    int init_ordinal;
    int handle_ordinal;
    int config_ordinal;
    int map_floats_ordinal;
    int map_strs_ordinal;

    void *model;        /* Box(Model), between events */
    int model_is_live;
} Plugin;

/* ========================================================================= */
/* Binding the platform's hosted functions                                   */
/* ========================================================================= */

static int symbol_is(const char *symbol, size_t len, const char *name) {
    return len == strlen(name) && memcmp(symbol, name, len) == 0;
}

static void *resolve_hosted(void *ctx, const char *symbol, size_t len) {
    (void)ctx;
    if (symbol_is(symbol, len, "roc_vd_host_exec")) return (void *)roc_vd_host_exec;
    if (symbol_is(symbol, len, "roc_vd_host_eval")) return (void *)roc_vd_host_eval;
    if (symbol_is(symbol, len, "roc_vd_host_reply")) return (void *)roc_vd_host_reply;
    if (symbol_is(symbol, len, "roc_vd_host_id")) return (void *)roc_vd_host_id;
    return NULL;
}

static int ordinal_of(void *program, const char *name) {
    return roc_embed_entrypoint(program, name, strlen(name));
}

static void hand_back_error(char *error, char **error_out) {
    if (error_out != NULL) {
        *error_out = error;
    } else {
        roc_embed_free_error(error);
    }
}

/* ========================================================================= */
/* What VisiData calls                                                       */
/* ========================================================================= */

int roc_vd_engine_abi_version(void) {
    return ROC_VD_ENGINE_ABI_VERSION;
}

void *roc_vd_load(const roc_vd_api_T *api, int handle,
                  const char *path, size_t path_len, char **error_out) {
    Plugin *plugin;
    char *error = NULL;

    if (error_out != NULL) *error_out = NULL;

    if (api == NULL || api->abi_version != ROC_VD_ABI_VERSION) {
        hand_back_error(strdup("this engine was built for a different visidata_roc"), error_out);
        return NULL;
    }
    if (roc_embed_abi_version() != ROC_EMBED_ABI_VERSION) {
        hand_back_error(strdup("this engine was built against a different Roc embedding library"),
                        error_out);
        return NULL;
    }

    plugin = calloc(1, sizeof *plugin);
    if (plugin == NULL) return NULL;
    plugin->handle = handle;

    roc_vd_enter(api, handle);
    plugin->program = roc_embed_open(path, path_len, NULL, resolve_hosted, &error);
    if (plugin->program == NULL) {
        free(plugin);
        hand_back_error(error, error_out);
        return NULL;
    }

    plugin->init_ordinal = ordinal_of(plugin->program, "roc_vd_init");
    plugin->handle_ordinal = ordinal_of(plugin->program, "roc_vd_handle");
    plugin->config_ordinal = ordinal_of(plugin->program, "roc_vd_config");
    plugin->map_floats_ordinal = ordinal_of(plugin->program, "roc_vd_map_floats");
    plugin->map_strs_ordinal = ordinal_of(plugin->program, "roc_vd_map_strs");

    /* What this file turned out to be, from what it provides. */
    if (plugin->init_ordinal >= 0 && plugin->handle_ordinal >= 0) {
        plugin->kind = ROC_VD_KIND_PLUGIN;
    } else if (plugin->config_ordinal >= 0) {
        plugin->kind = ROC_VD_KIND_CONFIG;
    } else if (plugin->map_floats_ordinal >= 0) {
        plugin->kind = ROC_VD_KIND_COLUMN;
    } else {
        roc_embed_close(plugin->program);
        free(plugin);
        hand_back_error(strdup(
            "this is not a roc-visidata file: it provides none of roc_vd_init/"
            "roc_vd_config/roc_vd_map_floats (check the platform in its app header)"),
            error_out);
        return NULL;
    }

    if (plugin->kind == ROC_VD_KIND_PLUGIN) {
        /* init! builds the first model, which the plugin keeps from here on. */
        if (roc_embed_call(plugin->program, plugin->init_ordinal, NULL,
                           &plugin->model, &error) != 0) {
            roc_embed_close(plugin->program);
            free(plugin);
            hand_back_error(error, error_out);
            return NULL;
        }
        plugin->model_is_live = 1;
    }
    return plugin;
}

int roc_vd_kind(void *handle) {
    Plugin *plugin = handle;
    return plugin == NULL ? 0 : plugin->kind;
}

char *roc_vd_event(void *handle, const roc_vd_api_T *api,
                   const char *json, size_t len, size_t *out_len) {
    Plugin *plugin = handle;
    unsigned char *args;
    size_t args_size;
    RocStr event;
    void *next_model = NULL;
    char *error = NULL;

    if (out_len != NULL) *out_len = 0;
    if (plugin == NULL || !plugin->model_is_live) return NULL;

    roc_vd_enter(api, plugin->handle);
    roc_vd_clear_reply();

    args_size = roc_embed_args_size(plugin->program, plugin->handle_ordinal);
    args = calloc(1, args_size == 0 ? 1 : args_size);
    if (args == NULL) return NULL;

    /* handle! takes (Box(Model), Str), packed where the library says. */
    event = roc_str_from(json, len);
    memcpy(args + roc_embed_arg_offset(plugin->program, plugin->handle_ordinal, 0),
           &plugin->model, sizeof plugin->model);
    memcpy(args + roc_embed_arg_offset(plugin->program, plugin->handle_ordinal, 1),
           &event, sizeof event);

    if (roc_embed_call(plugin->program, plugin->handle_ordinal, args, &next_model, &error) != 0) {
        /* The model went with the failed call, so this plugin is done. */
        plugin->model_is_live = 0;
        if (api != NULL && error != NULL) {
            char message[512];

            snprintf(message, sizeof message, "roc-visidata: %s", error);
            api->message(message, strlen(message), 1);
        }
        roc_embed_free_error(error);
        free(args);
        return NULL;
    }
    free(args);
    plugin->model = next_model;
    return roc_vd_take_reply(out_len);
}

int roc_vd_run_config(void *handle, const roc_vd_api_T *api, char **error_out) {
    Plugin *plugin = handle;
    char *error = NULL;

    if (error_out != NULL) *error_out = NULL;
    if (plugin == NULL || plugin->config_ordinal < 0) return 1;

    roc_vd_enter(api, plugin->handle);
    if (roc_embed_call(plugin->program, plugin->config_ordinal, NULL, NULL, &error) != 0) {
        hand_back_error(error, error_out);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------------- */
/* The bulk path                                                             */
/* ------------------------------------------------------------------------- */

/* A List(F64) laid out the way Roc expects: a refcount word, then elements. */
static int roc_list_f64(const double *values, size_t count, RocList *out) {
    uint8_t *base = malloc(sizeof(size_t) + count * sizeof(double));
    uint8_t *elements;

    if (base == NULL) return 1;
    elements = base + sizeof(size_t);
    ((intptr_t *)elements)[-1] = 1;
    memcpy(elements, values, count * sizeof(double));
    out->elements = elements;
    out->length = count;
    out->capacity_or_alloc_ptr = count << 1;
    return 0;
}

static void roc_list_release(RocList list) {
    if (list.elements == NULL) return;
    if (((intptr_t *)list.elements)[-1] == INTPTR_MIN) return;
    free(list.elements - sizeof(size_t));
}

int roc_vd_map_floats(void *handle, const roc_vd_api_T *api,
                      const double *values, size_t len,
                      double **out, size_t *out_len, char **error_out) {
    Plugin *plugin = handle;
    unsigned char *args;
    RocList in, result;
    char *error = NULL;
    double *copy;

    if (error_out != NULL) *error_out = NULL;
    if (out != NULL) *out = NULL;
    if (out_len != NULL) *out_len = 0;
    if (plugin == NULL || plugin->map_floats_ordinal < 0) {
        hand_back_error(strdup("this file has no map_floats"), error_out);
        return 1;
    }

    roc_vd_enter(api, plugin->handle);

    if (roc_list_f64(values, len, &in) != 0) return 1;
    args = calloc(1, roc_embed_args_size(plugin->program, plugin->map_floats_ordinal));
    if (args == NULL) {
        roc_list_release(in);
        return 1;
    }
    memcpy(args + roc_embed_arg_offset(plugin->program, plugin->map_floats_ordinal, 0),
           &in, sizeof in);

    if (roc_embed_call(plugin->program, plugin->map_floats_ordinal, args, &result, &error) != 0) {
        free(args);
        hand_back_error(error, error_out);
        return 1;
    }
    free(args);

    /* Hand Python a plain array it can read without knowing Roc's layout. */
    copy = malloc(result.length * sizeof(double) + 1);
    if (copy != NULL) {
        memcpy(copy, result.elements, result.length * sizeof(double));
        if (out != NULL) *out = copy;
        if (out_len != NULL) *out_len = result.length;
    }
    /* When a map returns its argument unchanged the result aliases the list
     * Roc already consumed, so releasing it again would be a double free. */
    if (result.elements != in.elements) roc_list_release(result);
    return copy == NULL ? 1 : 0;
}

void roc_vd_free_floats(double *values) {
    free(values);
}

void roc_vd_free(char *ptr) {
    free(ptr);
}

void roc_vd_free_error(char *message) {
    roc_embed_free_error(message);
}

void roc_vd_unload(void *handle) {
    Plugin *plugin = handle;

    if (plugin == NULL) return;
    plugin->model_is_live = 0;
    roc_embed_close(plugin->program);
    free(plugin);
}
