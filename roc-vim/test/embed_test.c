/*
 * Test the source-loading engine without Vim.
 *
 * This plays Vim's side of the in-process API: it hands the engine a `.roc`
 * file, answers the plugin's calls back into "Vim", sends it events, and
 * checks what the plugin did. A failure here is the engine or the platform,
 * not the editor.
 *
 * Build and run:
 *     cc -o embed_test test/embed_test.c -ldl && ./embed_test <plugin.roc>
 */

#define _POSIX_C_SOURCE 200809L

#include "../platform-inprocess/roc_vim_api.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* What the engine exports for Vim to call. */
typedef int (*source_abi_version_fn)(void);
typedef void *(*source_load_fn)(const roc_vim_api_T *api, int handle,
                                const char *path, size_t path_len, char **error_out);
typedef char *(*source_event_fn)(void *plugin, const roc_vim_api_T *api,
                                 const char *json, size_t len, size_t *out_len);
typedef void (*source_free_fn)(char *ptr);
typedef void (*source_unload_fn)(void *plugin);

static int failures;
static int ex_count;
static char ex_commands[64][512];
static char messages[64][512];
static int message_count;

static void check(int condition, const char *description) {
    printf("  %s %s\n", condition ? "ok  " : "FAIL", description);
    if (!condition) {
        failures++;
    }
}

/* ---- Vim's side of the table a plugin calls ---------------------------- */

static void api_ex(const char *cmd, size_t len) {
    if (ex_count < 64) {
        size_t copy = len < 511 ? len : 511;
        memcpy(ex_commands[ex_count], cmd, copy);
        ex_commands[ex_count][copy] = '\0';
        ex_count++;
    }
}

static char *api_eval_json(const char *expr, size_t len, size_t *out_len) {
    /* Stand in for Vim's evaluator with a couple of canned answers. */
    const char *answer = "null";

    if (len >= 11 && memcmp(expr, "expand('%')", 11) == 0) {
        answer = "\"notes.txt\"";
    } else if (strstr(expr, "roc#") != NULL) {
        answer = "1"; /* roc#subscribe, roc#add_command, ... */
    } else if (strstr(expr, "line(") != NULL) {
        answer = "2";
    }

    {
        size_t answer_len = strlen(answer);
        char *copy = malloc(answer_len + 1);

        if (copy == NULL) {
            return NULL;
        }
        memcpy(copy, answer, answer_len + 1);
        if (out_len != NULL) {
            *out_len = answer_len;
        }
        return copy;
    }
}

static void api_free_result(char *ptr) {
    free(ptr);
}

static void api_message(const char *text, size_t len, int is_error) {
    if (message_count < 64) {
        size_t copy = len < 511 ? len : 511;
        memcpy(messages[message_count], text, copy);
        messages[message_count][copy] = '\0';
        message_count++;
    }
    printf("       %s%.*s\n", is_error ? "error: " : "message: ", (int)len, text);
}

static const roc_vim_api_T api = {
    ROC_VIM_ABI_VERSION,
    api_ex,
    api_eval_json,
    api_free_result,
    api_message,
};

static int saw_ex(const char *needle) {
    for (int i = 0; i < ex_count; i++) {
        if (strstr(ex_commands[i], needle) != NULL) {
            return 1;
        }
    }
    return 0;
}

static int saw_message(const char *needle) {
    for (int i = 0; i < message_count; i++) {
        if (strstr(messages[i], needle) != NULL) {
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *engine_path = argc > 1 ? argv[1] : "embed/libroc_vim_embed.so";
    const char *plugin_path = argc > 2 ? argv[2] : "examples-inprocess/hello.roc";
    void *engine;
    source_abi_version_fn abi_version;
    source_load_fn load;
    source_event_fn event;
    source_free_fn free_reply;
    source_unload_fn unload;
    char *error = NULL;
    void *plugin;
    char *reply;
    size_t reply_len = 0;

    engine = dlopen(engine_path, RTLD_NOW | RTLD_LOCAL);
    if (engine == NULL) {
        fprintf(stderr, "could not load the engine at %s: %s\n", engine_path, dlerror());
        return 2;
    }

    abi_version = (source_abi_version_fn)dlsym(engine, "roc_vim_source_abi_version");
    load = (source_load_fn)dlsym(engine, "roc_vim_source_load");
    event = (source_event_fn)dlsym(engine, "roc_vim_source_event");
    free_reply = (source_free_fn)dlsym(engine, "roc_vim_source_free");
    unload = (source_unload_fn)dlsym(engine, "roc_vim_source_unload");
    if (abi_version == NULL || load == NULL || event == NULL || unload == NULL) {
        fprintf(stderr, "the engine is missing its entry points\n");
        return 2;
    }

    printf("engine abi version %d, loading %s\n", abi_version(), plugin_path);

    plugin = load(&api, 1, plugin_path, strlen(plugin_path), &error);
    if (plugin == NULL) {
        fprintf(stderr, "could not load the plugin:\n%s\n", error ? error : "(no message)");
        return 1;
    }
    check(1, "compiled and started the plugin from source");

    /* The checks below are about examples-inprocess/hello.roc in particular.
     * Any other plugin is only checked as far as compiling and loading. */
    if (strstr(plugin_path, "hello.roc") == NULL) {
        unload(plugin);
        dlclose(engine);
        printf("\nloaded %s; skipping the checks that are about hello.roc\n", plugin_path);
        return failures == 0 ? 0 : 1;
    }

    /* A command, which makes the plugin ask Vim about the buffer. */
    {
        const char *json = "{\"event\":\"command:RocHello\",\"data\":{\"args\":\"\"}}";

        reply = event(plugin, &api, json, strlen(json), &reply_len);
        if (reply != NULL && free_reply != NULL) {
            free_reply(reply);
        }
    }
    check(saw_message("hello from Roc") || saw_ex("hello from Roc"),
          "plugin answered the command");
    check(saw_message("notes.txt") || saw_ex("notes.txt"),
          "plugin asked Vim which file is open, and used the answer");

    /* Two writes: the count only rises if the model survives between events. */
    {
        const char *json = "{\"event\":\"BufWritePost\",\"data\":{\"file\":\"notes.txt\"}}";

        reply = event(plugin, &api, json, strlen(json), &reply_len);
        if (reply != NULL && free_reply != NULL) {
            free_reply(reply);
        }
        reply = event(plugin, &api, json, strlen(json), &reply_len);
        if (reply != NULL && free_reply != NULL) {
            free_reply(reply);
        }
    }
    check(saw_message("2 write") || saw_ex("2 write"),
          "plugin kept its model between events");

    unload(plugin);
    check(1, "unloaded the plugin");

    dlclose(engine);

    if (failures != 0) {
        printf("\n%d check(s) failed\n", failures);
        return 1;
    }
    printf("\nall checks passed\n");
    return 0;
}
