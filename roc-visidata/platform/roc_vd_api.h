/*
 * The contract between VisiData and a Roc plugin running inside it.
 *
 * The Python side (visidata_roc/_ffi.py) builds this struct out of ctypes
 * callbacks; the C side calls through it. Both check ROC_VD_ABI_VERSION before
 * using it, so a mismatch is a clear message rather than a call through the
 * wrong offsets.
 *
 * Only text crosses here — Python source for commands and expressions, JSON
 * for values — so nothing in the Python package depends on how Roc lays out
 * its types.
 */

#ifndef ROC_VD_API_H
#define ROC_VD_API_H

#include <stddef.h>

/* The function table below: bumped when its shape changes. Version 2 added
 * read_file, so a loader can get a file's bytes without them being JSON
 * encoded on the way through. */
#define ROC_VD_ABI_VERSION 2

/* What a plugin compiled to a shared library exports, which is a separate
 * contract with its own history: version 2 made it per-instance, so two sheets
 * can open the same loader without sharing one table. */
#define ROC_VD_PLUGIN_ABI_VERSION 2

typedef struct roc_vd_api roc_vd_api_T;
struct roc_vd_api {
    int abi_version;

    /* Execute a Python statement in VisiData's globals. */
    void (*exec)(const char *stmt, size_t len);

    /* Evaluate a Python expression and return `{"ok":...}` or `{"err":...}` as
     * JSON text, or NULL. Free the result with free_result(). */
    char *(*eval_json)(const char *expr, size_t len, size_t *out_len);

    /* Free something eval_json() returned. */
    void (*free_result)(char *ptr);

    /* Show a message, as vd.status() does, or as vd.error() when is_error. */
    void (*message)(const char *text, size_t len, int is_error);

    /* Read a file and return its bytes, or NULL. Free with free_result().
     * A loader could ask for this through eval_json, but then the whole file
     * is JSON encoded and decoded on the way past — about a fifth of what
     * loading costs (bench/RESULTS.md §4). */
    char *(*read_file)(const char *path, size_t len, size_t *out_len);
};

#endif /* ROC_VD_API_H */
