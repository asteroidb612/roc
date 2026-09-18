/*
 * A stub plugin library, written in C, for testing Vim's +roc interface on its
 * own. It answers the same C API a Roc plugin's host does, so a failure here
 * is Vim's side of the boundary rather than Roc's.
 *
 * Build:  cc -shared -fPIC -o stub.so inprocess_stub.c
 */

#include "../platform-inprocess/roc_vim_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const roc_vim_api_T *vim;
static int my_handle;
static int events_seen;

int roc_vim_abi_version(void) {
    return ROC_VIM_ABI_VERSION;
}

int roc_vim_plugin_init(const roc_vim_api_T *api, int handle) {
    char command[256];

    if (api == NULL || api->abi_version != ROC_VIM_ABI_VERSION) {
        return 1;
    }
    vim = api;
    my_handle = handle;

    /* Prove the plugin can run commands in Vim as it starts. */
    snprintf(command, sizeof command, "let g:stub_handle = %d", handle);
    vim->ex(command, strlen(command));

    /* ...and ask Vim something. */
    {
        const char *expr = "1 + 41";
        size_t len = 0;
        char *answer = vim->eval_json(expr, strlen(expr), &len);

        if (answer != NULL) {
            snprintf(command, sizeof command, "let g:stub_eval = '%s'", answer);
            vim->ex(command, strlen(command));
            vim->free_result(answer);
        }
    }
    return 0;
}

char *roc_vim_plugin_event(const char *json, size_t len, size_t *out_len) {
    char command[1024];
    char *reply;

    events_seen++;

    /* Record what arrived, so the test can look at it from Vimscript. */
    snprintf(command, sizeof command, "let g:stub_events = get(g:, 'stub_events', []) + [%.*s]",
             (int)(len < 800 ? len : 800), json);
    vim->ex(command, strlen(command));

    /* Answer with a JSON value, which Vim decodes for whoever called. */
    reply = malloc(64);
    if (reply == NULL) {
        return NULL;
    }
    snprintf(reply, 64, "{\"seen\":%d,\"handle\":%d}", events_seen, my_handle);
    if (out_len != NULL) {
        *out_len = strlen(reply);
    }
    return reply;
}

void roc_vim_plugin_free(char *ptr) {
    free(ptr);
}

void roc_vim_plugin_deinit(void) {
    if (vim != NULL) {
        const char *command = "let g:stub_unloaded = 1";
        vim->ex(command, strlen(command));
    }
    vim = NULL;
}
