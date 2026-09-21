/*
 * What visidata_roc calls, through ctypes.
 *
 * The engine compiles a `.roc` file in VisiData's own process and runs it
 * through Roc's interpreter — the pipeline the playground uses in a browser
 * tab, pointed at a spreadsheet instead. There is no build step and no
 * artifact.
 */

#ifndef ROC_VD_ENGINE_H
#define ROC_VD_ENGINE_H

#include <stddef.h>
#include "../platform/roc_vd_api.h"

#define ROC_VD_ENGINE_ABI_VERSION 1

/* What a loaded file turned out to be, from the entrypoints it provides. */
#define ROC_VD_KIND_PLUGIN 1
#define ROC_VD_KIND_CONFIG 2
#define ROC_VD_KIND_COLUMN 3

int roc_vd_engine_abi_version(void);

/* Compile `path` and, for a plugin, run its `init!`. Returns NULL on failure
 * with an owned message in `error_out`. */
void *roc_vd_load(const roc_vd_api_T *api, int handle,
                  const char *path, size_t path_len, char **error_out);

int roc_vd_kind(void *plugin);

/* Hand one event to a plugin. Returns what it passed to `VisiData.reply!`,
 * or NULL, with the length in `out_len`. Free it with roc_vd_free. */
char *roc_vd_event(void *plugin, const roc_vd_api_T *api,
                   const char *json, size_t len, size_t *out_len);

/* Run a config's `main!`. Returns 0 on success. */
int roc_vd_run_config(void *plugin, const roc_vd_api_T *api, char **error_out);

/* Map a whole column of numbers. On success writes an owned array of
 * `out_len` doubles to `out`, to be freed with roc_vd_free_floats. */
int roc_vd_map_floats(void *plugin, const roc_vd_api_T *api,
                      const double *values, size_t len,
                      double **out, size_t *out_len, char **error_out);

void roc_vd_free_floats(double *values);
void roc_vd_free(char *ptr);
void roc_vd_free_error(char *message);
void roc_vd_unload(void *plugin);

#endif /* ROC_VD_ENGINE_H */
