/*
 * roc-vim in-process host: the native side of a plugin that runs inside Vim.
 *
 * This file is linked into the shared library `roc build` produces. Vim loads
 * that library with dlopen() (see Vim's if_roc.c), hands it the table of Vim
 * functions below, and then calls it whenever something happens.
 *
 * The plugin's model lives here, boxed: Roc hands it back on every event, and
 * this file keeps the box between events.
 */

#define _POSIX_C_SOURCE 200809L

#include "roc_platform_abi.h"
#include "roc_vim_api.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * A Roc `crash` must not take Vim with it. Each entry point sets a landing
 * point before calling into Roc; roc_crashed() jumps back to it.
 *
 * Jumping out of Roc code abandons whatever it had allocated. That is a leak,
 * and the plugin stops, but Vim and the buffers stay as they were.
 */
static jmp_buf crash_landing;
static int crash_landing_set;

#define GUARD_CALL_INTO_ROC(on_crash)					\
    do {								\
	crash_landing_set = 1;						\
	if (setjmp(crash_landing) != 0) {				\
	    crash_landing_set = 0;					\
	    on_crash;							\
	}								\
    } while (0)

#define GUARD_DONE() (crash_landing_set = 0)

/* ========================================================================= */
/* Allocation                                                                */
/* ========================================================================= */

void *roc_alloc(size_t length, size_t alignment) {
    if (length == 0) {
        length = 1;
    }
    if (alignment <= 2 * sizeof(void *)) {
        return malloc(length);
    }
    size_t rounded = (length + alignment - 1) & ~(alignment - 1);
    return aligned_alloc(alignment, rounded);
}

void roc_dealloc(void *ptr, size_t alignment) {
    (void)alignment;
    free(ptr);
}

void *roc_realloc(void *ptr, size_t new_length, size_t alignment) {
    (void)alignment;
    return realloc(ptr, new_length == 0 ? 1 : new_length);
}

/* ========================================================================= */
/* RocStr                                                                    */
/* ========================================================================= */

static int roc_str_is_small(const RocStr *str) {
    return (intptr_t)str->length < 0;
}

static size_t roc_str_len(const RocStr *str) {
    if (roc_str_is_small(str)) {
        return ((const uint8_t *)str)[sizeof(RocStr) - 1u] ^ 0x80u;
    }
    return str->length;
}

static const char *roc_str_bytes(const RocStr *str) {
    if (roc_str_is_small(str)) {
        return (const char *)str;
    }
    return (const char *)str->bytes;
}

static void roc_str_decref(RocStr str) {
    if (roc_str_is_small(&str)) {
        return;
    }
    uint8_t *alloc_ptr = ((str.capacity_or_alloc_ptr & 1u) != 0)
                             ? (uint8_t *)(str.capacity_or_alloc_ptr & ~(uintptr_t)1u)
                             : str.bytes;
    if (alloc_ptr == NULL) {
        return;
    }
    intptr_t *refcount = (intptr_t *)alloc_ptr - 1;
    if (*refcount == 0) {
        return; /* static data */
    }
    *refcount -= 1;
    if (*refcount == 0) {
        roc_dealloc(alloc_ptr - sizeof(size_t), _Alignof(size_t));
    }
}

static RocStr roc_str_from(const char *data, size_t len) {
    RocStr out;
    memset(&out, 0, sizeof out);

    if (len < sizeof(RocStr)) {
        if (len > 0) {
            memcpy(&out, data, len);
        }
        ((uint8_t *)&out)[sizeof(RocStr) - 1u] = (uint8_t)(len | 0x80u);
        return out;
    }

    uint8_t *base = roc_alloc(sizeof(size_t) + len, _Alignof(size_t));
    if (base == NULL) {
        ((uint8_t *)&out)[sizeof(RocStr) - 1u] = 0x80u;
        return out;
    }
    uint8_t *bytes = base + sizeof(size_t);
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
/* Plugin state                                                              */
/* ========================================================================= */

static const roc_vim_api_T *vim_api;
static RocBox model;            /* the plugin's model, between events */
static int model_is_live;
static char plugin_id[16] = "0";

/* What the current event wants to answer with, set by Vim.reply!. */
static char *pending_reply;
static size_t pending_reply_len;

static void say(const char *text, int is_error) {
    if (vim_api != NULL) {
        vim_api->message(text, strlen(text), is_error);
    } else {
        fprintf(stderr, "roc-vim: %s\n", text);
    }
}

void roc_dbg(const uint8_t *bytes, size_t len) {
    if (vim_api != NULL) {
        vim_api->message((const char *)bytes, len, 0);
    } else {
        fwrite(bytes, 1, len, stderr);
        fputc('\n', stderr);
    }
}

void roc_expect_failed(const uint8_t *bytes, size_t len) {
    if (vim_api != NULL) {
        vim_api->message((const char *)bytes, len, 1);
    } else {
        fwrite(bytes, 1, len, stderr);
        fputc('\n', stderr);
    }
}

/*
 * A crash inside a plugin must not take Vim down with it. Report it, forget
 * the model (it may be half-built), and return to Vim through the guard the
 * entry points set up.
 */
void roc_crashed(const uint8_t *bytes, size_t len) {
    char message[512];
    size_t copied = len < sizeof message - 32 ? len : sizeof message - 32;

    memcpy(message, "roc-vim: plugin crashed: ", 25);
    memcpy(message + 25, bytes, copied);
    message[25 + copied] = '\0';
    say(message, 1);

    model_is_live = 0;
    if (crash_landing_set) {
        crash_landing_set = 0;
        longjmp(crash_landing, 1);
    }
    /* Nothing to jump back to: this is not reachable from Vim's side. */
    abort();
}

/* ========================================================================= */
/* Hosted functions: what the Roc side calls                                 */
/* ========================================================================= */

void roc_vim_host_ex(RocStr arg0) {
    if (vim_api != NULL) {
        vim_api->ex(roc_str_bytes(&arg0), roc_str_len(&arg0));
    }
    roc_str_decref(arg0);
}

RocStr roc_vim_host_eval(RocStr arg0) {
    RocStr result;
    char *answer;
    size_t answer_len = 0;

    if (vim_api == NULL) {
        roc_str_decref(arg0);
        return roc_str_from_cstr("{\"err\":\"not loaded into Vim\"}");
    }

    answer = vim_api->eval_json(roc_str_bytes(&arg0), roc_str_len(&arg0), &answer_len);
    roc_str_decref(arg0);

    if (answer == NULL) {
        return roc_str_from_cstr("{\"err\":\"Vim could not evaluate that\"}");
    }

    /* Wrap the answer: {"ok": <json>} */
    {
        size_t total = answer_len + 8;
        char *envelope = malloc(total + 1);

        if (envelope == NULL) {
            vim_api->free_result(answer);
            return roc_str_from_cstr("{\"err\":\"out of memory\"}");
        }
        memcpy(envelope, "{\"ok\":", 6);
        memcpy(envelope + 6, answer, answer_len);
        envelope[6 + answer_len] = '}';
        envelope[7 + answer_len] = '\0';
        result = roc_str_from(envelope, answer_len + 7);
        free(envelope);
    }
    vim_api->free_result(answer);
    return result;
}

void roc_vim_host_message(RocStr arg0, bool arg1) {
    if (vim_api != NULL) {
        vim_api->message(roc_str_bytes(&arg0), roc_str_len(&arg0), arg1 ? 1 : 0);
    }
    roc_str_decref(arg0);
}

void roc_vim_host_reply(RocStr arg0) {
    size_t len = roc_str_len(&arg0);
    char *copy = malloc(len + 1);

    if (copy != NULL) {
        memcpy(copy, roc_str_bytes(&arg0), len);
        copy[len] = '\0';
        free(pending_reply);
        pending_reply = copy;
        pending_reply_len = len;
    }
    roc_str_decref(arg0);
}

RocStr roc_vim_host_id(void) {
    return roc_str_from_cstr(plugin_id);
}

/* ========================================================================= */
/* The library's outward-facing C API: what Vim calls                        */
/* ========================================================================= */

int roc_vim_abi_version(void) {
    return ROC_VIM_ABI_VERSION;
}

/*
 * A plugin compiled to a shared library calls the entrypoints the Roc compiler
 * linked in. The source-loading engine (roc-vim/embed/engine.c) includes this
 * file for its hosted functions but reaches the same entrypoints through the
 * interpreter, so it defines ROC_VIM_EMBEDDED and supplies its own.
 */
#ifndef ROC_VIM_EMBEDDED

int roc_vim_plugin_init(const roc_vim_api_T *api, int handle) {
    if (api == NULL || api->abi_version != ROC_VIM_ABI_VERSION) {
        return 1;
    }
    vim_api = api;
    snprintf(plugin_id, sizeof plugin_id, "%d", handle);

    /* The plugin crashed while starting up. */
    GUARD_CALL_INTO_ROC(return 1);
    model = roc_vim_init();
    GUARD_DONE();
    model_is_live = 1;
    return 0;
}

char *roc_vim_plugin_event(const char *json, size_t len, size_t *out_len) {
    RocStr event;
    char *reply;

    if (out_len != NULL) {
        *out_len = 0;
    }
    if (!model_is_live) {
        return NULL;
    }

    free(pending_reply);
    pending_reply = NULL;
    pending_reply_len = 0;

    event = roc_str_from(json, len);
    /* The plugin crashed: its model is gone, so it takes no more events. */
    GUARD_CALL_INTO_ROC(return NULL);
    model = roc_vim_handle(model, event);
    GUARD_DONE();

    reply = pending_reply;
    if (out_len != NULL) {
        *out_len = pending_reply_len;
    }
    pending_reply = NULL;
    pending_reply_len = 0;
    return reply;
}

#endif /* !ROC_VIM_EMBEDDED */

void roc_vim_plugin_free(char *ptr) {
    free(ptr);
}

void roc_vim_plugin_deinit(void) {
    free(pending_reply);
    pending_reply = NULL;
    pending_reply_len = 0;
    model_is_live = 0;
    vim_api = NULL;
}
