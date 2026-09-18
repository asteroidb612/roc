/*
 * The contract between Vim and a Roc plugin loaded into it.
 *
 * Vim's if_roc.c defines the same struct. Both sides check ROC_VIM_ABI_VERSION
 * before using it, so a plugin built against an older Vim refuses to load
 * rather than calling through the wrong offsets.
 */

#ifndef ROC_VIM_API_H
#define ROC_VIM_API_H

#include <stddef.h>

#define ROC_VIM_ABI_VERSION 1

typedef struct roc_vim_api roc_vim_api_T;
struct roc_vim_api {
    int abi_version;

    /* Run an Ex command, as though it were typed after a colon. */
    void (*ex)(const char *cmd, size_t len);

    /* Evaluate a Vim expression and return its value as JSON text, or NULL if
     * it could not be evaluated. Free the result with free_result(). */
    char *(*eval_json)(const char *expr, size_t len, size_t *out_len);

    /* Free something eval_json() returned. */
    void (*free_result)(char *ptr);

    /* Show a message, as :echomsg does, or as an error when is_error is set. */
    void (*message)(const char *text, size_t len, int is_error);
};

/*
 * What a plugin's shared library exports, and Vim looks up by name:
 *
 *   int   roc_vim_abi_version(void);
 *   int   roc_vim_plugin_init(const roc_vim_api_T *api, int handle);
 *   char *roc_vim_plugin_event(const char *json, size_t len, size_t *out_len);
 *   void  roc_vim_plugin_free(char *ptr);
 *   void  roc_vim_plugin_deinit(void);
 */

#endif /* ROC_VIM_API_H */
