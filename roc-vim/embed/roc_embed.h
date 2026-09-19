/*
 * The C API of libroc_embed: compiling and running Roc source in this process.
 *
 * The library is built from the Roc compiler itself (see compiler-patch/). It
 * compiles a `.roc` application in memory and calls its platform entrypoints
 * through the interpreter, which is how a host runs Roc source without
 * building an artifact first.
 *
 * The host provides its platform's hosted functions through a resolver: the
 * library asks for each hosted symbol by name and expects back an ordinary C
 * function with the signature that platform declares.
 */

#ifndef ROC_EMBED_H
#define ROC_EMBED_H

#include <stddef.h>

#define ROC_EMBED_ABI_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

/* Return the C function implementing `symbol`, or NULL if the host has none.
 * A missing hosted function fails the load rather than the first call. */
typedef void *(*roc_embed_resolve_fn)(void *ctx, const char *symbol, size_t symbol_len);

int roc_embed_abi_version(void);

/* Compile the app at `path`. Returns NULL on failure, and when `error_out` is
 * given, an owned message to show and then free with roc_embed_free_error. */
void *roc_embed_open(const char *path, size_t path_len,
                     void *resolver_ctx, roc_embed_resolve_fn resolver,
                     char **error_out);

void roc_embed_close(void *program);

/* The ordinal of the entrypoint with this symbol name, or -1. */
int roc_embed_entrypoint(void *program, const char *symbol, size_t symbol_len);
int roc_embed_entrypoint_count(void *program);

/* How to lay out an entrypoint's arguments: a buffer of roc_embed_args_size()
 * bytes, with argument `i` written at roc_embed_arg_offset(program, ord, i). */
size_t roc_embed_args_size(void *program, int ordinal);
size_t roc_embed_arg_offset(void *program, int ordinal, size_t index);
size_t roc_embed_arg_count(void *program, int ordinal);
size_t roc_embed_ret_size(void *program, int ordinal);

/* Call an entrypoint. Returns 0 on success; on failure returns 1 and, when
 * `error_out` is given, an owned message. */
int roc_embed_call(void *program, int ordinal, void *args, void *ret, char **error_out);

void roc_embed_free_error(char *message);

#ifdef __cplusplus
}
#endif

#endif /* ROC_EMBED_H */
