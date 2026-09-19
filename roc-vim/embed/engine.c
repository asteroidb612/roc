/*
 * The source-loading engine: Roc plugins that Vim runs from their source.
 *
 * This is the same idea as a compiled in-process plugin, with the compiler
 * moved inside. Vim hands a `.roc` file to `roc_vim_source_load`, which
 * compiles it here (libroc_embed, built from the Roc compiler) and then calls
 * its entrypoints through the interpreter. There is no build step and no
 * artifact: editing the file and reloading is the whole loop.
 *
 * The plugin's effects are the same hosted functions a compiled plugin uses,
 * so the two kinds of plugin are the same program run two ways. They come from
 * platform-inprocess/host.c, included below; ROC_VIM_EMBEDDED leaves out that
 * file's entrypoint glue, which only a linked plugin can have.
 */

#define ROC_VIM_EMBEDDED 1
#include "../platform-inprocess/host.c"

#include "roc_embed.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Bumped when the functions Vim looks up below change shape. */
#define ROC_VIM_SOURCE_ABI_VERSION 1

typedef struct {
    void *program;       /* what libroc_embed compiled */
    int init_ordinal;
    int handle_ordinal;
    void *model;         /* Box(Model), between events */
    int model_is_live;
    int vim_handle;
} SourcePlugin;

/* ========================================================================= */
/* Hosted functions                                                          */
/* ========================================================================= */

static int symbol_is(const char *symbol, size_t len, const char *name) {
    return len == strlen(name) && memcmp(symbol, name, len) == 0;
}

/*
 * What the platform's `hosted` section declares, by name. The interpreter
 * calls these with the same C ABI a linked host would, so they are the very
 * functions a compiled plugin uses.
 */
static void *resolve_hosted(void *ctx, const char *symbol, size_t len) {
    (void)ctx;
    if (symbol_is(symbol, len, "roc_vim_host_ex")) return (void *)roc_vim_host_ex;
    if (symbol_is(symbol, len, "roc_vim_host_eval")) return (void *)roc_vim_host_eval;
    if (symbol_is(symbol, len, "roc_vim_host_message")) return (void *)roc_vim_host_message;
    if (symbol_is(symbol, len, "roc_vim_host_reply")) return (void *)roc_vim_host_reply;
    if (symbol_is(symbol, len, "roc_vim_host_id")) return (void *)roc_vim_host_id;
    return NULL;
}

/*
 * The hosted functions above read the file-scope state in host.c, which is
 * about whichever plugin is running right now. Point it at this one.
 */
static void enter_plugin(SourcePlugin *plugin, const roc_vim_api_T *api) {
    vim_api = api;
    snprintf(plugin_id, sizeof plugin_id, "%d", plugin->vim_handle);
}

/* ========================================================================= */
/* What Vim calls                                                            */
/* ========================================================================= */

int roc_vim_source_abi_version(void) {
    return ROC_VIM_SOURCE_ABI_VERSION;
}

/*
 * Compile `path` and run its `init!`, returning a plugin to call later.
 * Returns NULL on failure, with an owned message in `error_out`.
 */
void *roc_vim_source_load(const roc_vim_api_T *api, int handle,
                          const char *path, size_t path_len, char **error_out) {
    SourcePlugin *plugin;
    char *error = NULL;

    if (error_out != NULL) {
        *error_out = NULL;
    }
    if (api == NULL || api->abi_version != ROC_VIM_ABI_VERSION) {
        if (error_out != NULL) {
            *error_out = strdup("this engine was built for a different Vim");
        }
        return NULL;
    }
    if (roc_embed_abi_version() != ROC_EMBED_ABI_VERSION) {
        if (error_out != NULL) {
            *error_out = strdup("this engine was built against a different Roc embedding library");
        }
        return NULL;
    }

    plugin = calloc(1, sizeof *plugin);
    if (plugin == NULL) {
        return NULL;
    }
    plugin->vim_handle = handle;

    enter_plugin(plugin, api);
    plugin->program = roc_embed_open(path, path_len, NULL, resolve_hosted, &error);
    if (plugin->program == NULL) {
        free(plugin);
        if (error_out != NULL) {
            *error_out = error;
        } else {
            roc_embed_free_error(error);
        }
        return NULL;
    }

    plugin->init_ordinal = roc_embed_entrypoint(plugin->program, "roc_vim_init", 12);
    plugin->handle_ordinal = roc_embed_entrypoint(plugin->program, "roc_vim_handle", 14);
    if (plugin->init_ordinal < 0 || plugin->handle_ordinal < 0) {
        roc_embed_close(plugin->program);
        free(plugin);
        if (error_out != NULL) {
            *error_out = strdup(
                "this is not an in-process plugin: it provides no roc_vim_init/roc_vim_handle"
                " (its app header should be `app [Model, plugin]`)");
        }
        return NULL;
    }

    /* init! builds the first model, which the plugin keeps from here on. */
    if (roc_embed_call(plugin->program, plugin->init_ordinal, NULL, &plugin->model, &error) != 0) {
        roc_embed_close(plugin->program);
        free(plugin);
        if (error_out != NULL) {
            *error_out = error;
        } else {
            roc_embed_free_error(error);
        }
        return NULL;
    }
    plugin->model_is_live = 1;
    return plugin;
}

/*
 * Hand one event to the plugin. Returns whatever it answered with
 * `Vim.reply!`, or NULL, and the answer's length in `out_len`.
 */
char *roc_vim_source_event(void *handle, const roc_vim_api_T *api,
                           const char *json, size_t len, size_t *out_len) {
    SourcePlugin *plugin = handle;
    unsigned char *args;
    size_t args_size;
    RocStr event;
    void *next_model = NULL;
    char *error = NULL;
    char *reply;

    if (out_len != NULL) {
        *out_len = 0;
    }
    if (plugin == NULL || !plugin->model_is_live) {
        return NULL;
    }

    enter_plugin(plugin, api);

    free(pending_reply);
    pending_reply = NULL;
    pending_reply_len = 0;

    args_size = roc_embed_args_size(plugin->program, plugin->handle_ordinal);
    args = calloc(1, args_size == 0 ? 1 : args_size);
    if (args == NULL) {
        return NULL;
    }

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

            snprintf(message, sizeof message, "roc-vim: %s", error);
            api->message(message, strlen(message), 1);
        }
        roc_embed_free_error(error);
        free(args);
        return NULL;
    }
    free(args);
    plugin->model = next_model;

    reply = pending_reply;
    if (out_len != NULL) {
        *out_len = pending_reply_len;
    }
    pending_reply = NULL;
    pending_reply_len = 0;
    return reply;
}

void roc_vim_source_free(char *ptr) {
    free(ptr);
}

void roc_vim_source_free_error(char *message) {
    roc_embed_free_error(message);
}

void roc_vim_source_unload(void *handle) {
    SourcePlugin *plugin = handle;

    if (plugin == NULL) {
        return;
    }
    plugin->model_is_live = 0;
    roc_embed_close(plugin->program);
    free(plugin);
}
