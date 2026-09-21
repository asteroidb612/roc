/*
 * The hosted functions a Roc plugin calls, implemented against VisiData.
 *
 * Each one is an ordinary C function with the signature the platform's
 * `hosted` section declares: on a native target the interpreter calls them
 * through the platform C ABI, the same way a linked host would, so the very
 * same code serves an interpreted plugin and a compiled one.
 *
 * VisiData runs commands on background threads (visidata/threads.py), so the
 * "which plugin is running" state here is thread-local rather than file-scope.
 * Serializing a single plugin's events is the engine's job, not this file's.
 */

#include "roc_vd_api.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ========================================================================= */
/* The slice of Roc's ABI this file needs                                    */
/* ========================================================================= */

typedef struct {
    uint8_t *bytes;
    size_t capacity_or_alloc_ptr;
    size_t length;
} RocStr;

typedef struct {
    uint8_t *elements;
    size_t length;
    size_t capacity_or_alloc_ptr;
} RocList;

/* A small string carries its bytes inside the struct, with the length and a
 * flag in the final byte. */
static int roc_str_is_small(const RocStr *s) {
    return (((const uint8_t *)s)[sizeof(RocStr) - 1u] & 0x80u) != 0;
}

static const char *roc_str_bytes(const RocStr *s) {
    return roc_str_is_small(s) ? (const char *)s : (const char *)s->bytes;
}

static size_t roc_str_len(const RocStr *s) {
    return roc_str_is_small(s)
        ? (size_t)(((const uint8_t *)s)[sizeof(RocStr) - 1u] & 0x7fu)
        : s->length;
}

/* Roc transfers ownership of a refcounted argument to the hosted function, so
 * every one of them releases what it was given. */
static void roc_str_decref(RocStr s) {
    intptr_t *refcount;

    if (roc_str_is_small(&s) || s.bytes == NULL) return;
    refcount = ((intptr_t *)s.bytes) - 1;
    if (*refcount == INTPTR_MIN) return;  /* a literal in static data */
    *refcount -= 1;
    if (*refcount == 0) free((uint8_t *)s.bytes - sizeof(size_t));
}

static RocStr roc_str_from(const char *data, size_t len) {
    RocStr out;
    uint8_t *base, *bytes;

    memset(&out, 0, sizeof out);
    if (len < sizeof(RocStr)) {
        if (len > 0) memcpy(&out, data, len);
        ((uint8_t *)&out)[sizeof(RocStr) - 1u] = (uint8_t)(len | 0x80u);
        return out;
    }
    base = malloc(sizeof(size_t) + len);
    if (base == NULL) {
        ((uint8_t *)&out)[sizeof(RocStr) - 1u] = 0x80u;
        return out;
    }
    bytes = base + sizeof(size_t);
    ((intptr_t *)bytes)[-1] = 1;
    memcpy(bytes, data, len);
    out.bytes = bytes;
    out.capacity_or_alloc_ptr = len << 1;
    out.length = len;
    return out;
}

static RocStr roc_str_from_cstr(const char *text) {
    return roc_str_from(text, strlen(text));
}

/* ========================================================================= */
/* Which plugin is running on this thread                                    */
/* ========================================================================= */

typedef struct {
    const roc_vd_api_T *api;
    char id[24];
    char *reply;
    size_t reply_len;
} roc_vd_current_T;

static __thread roc_vd_current_T current;

/* Point the hosted functions at this plugin, for the duration of one call. */
static void roc_vd_enter(const roc_vd_api_T *api, int handle) {
    current.api = api;
    snprintf(current.id, sizeof current.id, "%d", handle);
}

static void roc_vd_clear_reply(void) {
    free(current.reply);
    current.reply = NULL;
    current.reply_len = 0;
}

/* Hand the pending reply to the caller, who now owns it. */
static char *roc_vd_take_reply(size_t *out_len) {
    char *reply = current.reply;

    if (out_len != NULL) *out_len = current.reply_len;
    current.reply = NULL;
    current.reply_len = 0;
    return reply;
}

/* ========================================================================= */
/* Hosted functions: what the Roc side calls                                 */
/* ========================================================================= */

void roc_vd_host_exec(RocStr arg0) {
    if (current.api != NULL) {
        current.api->exec(roc_str_bytes(&arg0), roc_str_len(&arg0));
    }
    roc_str_decref(arg0);
}

RocStr roc_vd_host_eval(RocStr arg0) {
    char *answer;
    size_t answer_len = 0;
    RocStr result;

    if (current.api == NULL) {
        roc_str_decref(arg0);
        return roc_str_from_cstr("{\"err\":\"not loaded into VisiData\"}");
    }

    answer = current.api->eval_json(roc_str_bytes(&arg0), roc_str_len(&arg0), &answer_len);
    roc_str_decref(arg0);

    if (answer == NULL) {
        return roc_str_from_cstr("{\"err\":\"VisiData could not evaluate that\"}");
    }
    result = roc_str_from(answer, answer_len);
    current.api->free_result(answer);
    return result;
}

void roc_vd_host_reply(RocStr arg0) {
    size_t len = roc_str_len(&arg0);
    char *copy = malloc(len + 1);

    if (copy != NULL) {
        memcpy(copy, roc_str_bytes(&arg0), len);
        copy[len] = '\0';
        roc_vd_clear_reply();
        current.reply = copy;
        current.reply_len = len;
    }
    roc_str_decref(arg0);
}

RocStr roc_vd_host_id(void) {
    return roc_str_from_cstr(current.id);
}
