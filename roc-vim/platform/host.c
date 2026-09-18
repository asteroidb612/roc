/*
 * roc-vim host: the native side of the platform.
 *
 * Vim starts a plugin as a job with `in_mode`/`out_mode` set to "json", which
 * means the two processes exchange `[number, value]` JSON messages over the
 * plugin's stdin and stdout. See `:help channel-use` in Vim.
 *
 * This file does three things:
 *   - writes channel commands (`["ex", ...]`, `["expr", ...]`, `["call", ...]`)
 *   - reads incoming messages, matching answers to the requests that asked for
 *     them and queueing everything else for the plugin to pick up
 *   - hands Roc the bytes, and Roc's bytes back to Vim
 *
 * Everything crossing into Roc is JSON text, so the only Roc types this host
 * has to know about are Str and I64.
 */

/* poll(), clock_gettime() and friends live behind this. */
#define _POSIX_C_SOURCE 200809L

#include "roc_platform_abi.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
    /* aligned_alloc requires a size that is a multiple of the alignment. */
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

void roc_dbg(const uint8_t *bytes, size_t len) {
    fwrite(bytes, 1, len, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

void roc_expect_failed(const uint8_t *bytes, size_t len) {
    fputs("expect failed: ", stderr);
    fwrite(bytes, 1, len, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

void roc_crashed(const uint8_t *bytes, size_t len) {
    fputs("plugin crashed: ", stderr);
    fwrite(bytes, 1, len, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    exit(1);
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

/* Release one owned reference to a string Roc handed us. */
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
        return; /* static data: its bytes live in the binary */
    }
    *refcount -= 1;
    if (*refcount == 0) {
        roc_dealloc(alloc_ptr - sizeof(size_t), _Alignof(size_t));
    }
}

/* Build a string to hand to Roc, which takes ownership of it. */
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
    ((intptr_t *)bytes)[-1] = 1; /* refcount */
    memcpy(bytes, data, len);

    out.bytes = bytes;
    out.capacity_or_alloc_ptr = len << 1; /* capacity, shifted past the slice bit */
    out.length = len;
    return out;
}

static RocStr roc_str_from_cstr(const char *text) {
    return roc_str_from(text, strlen(text));
}

/* ========================================================================= */
/* Growable byte buffers                                                     */
/* ========================================================================= */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} Buf;

static void buf_free(Buf *buf) {
    free(buf->data);
    buf->data = NULL;
    buf->len = 0;
    buf->cap = 0;
}

static void buf_reserve(Buf *buf, size_t extra) {
    if (buf->len + extra + 1 <= buf->cap) {
        return;
    }
    size_t cap = buf->cap == 0 ? 256 : buf->cap;
    while (cap < buf->len + extra + 1) {
        cap *= 2;
    }
    char *data = realloc(buf->data, cap);
    if (data == NULL) {
        fputs("roc-vim host: out of memory\n", stderr);
        exit(1);
    }
    buf->data = data;
    buf->cap = cap;
}

static void buf_add(Buf *buf, const char *data, size_t len) {
    buf_reserve(buf, len);
    memcpy(buf->data + buf->len, data, len);
    buf->len += len;
    buf->data[buf->len] = '\0';
}

static void buf_add_cstr(Buf *buf, const char *text) {
    buf_add(buf, text, strlen(text));
}

static void buf_add_char(Buf *buf, char c) {
    buf_add(buf, &c, 1);
}

static void buf_add_i64(Buf *buf, int64_t value) {
    char digits[24];
    int written = snprintf(digits, sizeof digits, "%lld", (long long)value);
    if (written > 0) {
        buf_add(buf, digits, (size_t)written);
    }
}

/* Append `text` as a JSON string literal, quotes and all. */
static void buf_add_json_str(Buf *buf, const char *text, size_t len) {
    buf_add_char(buf, '"');
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        switch (c) {
        case '"': buf_add_cstr(buf, "\\\""); break;
        case '\\': buf_add_cstr(buf, "\\\\"); break;
        case '\n': buf_add_cstr(buf, "\\n"); break;
        case '\r': buf_add_cstr(buf, "\\r"); break;
        case '\t': buf_add_cstr(buf, "\\t"); break;
        default:
            if (c < 0x20) {
                char escape[8];
                snprintf(escape, sizeof escape, "\\u%04x", c);
                buf_add_cstr(buf, escape);
            } else {
                buf_add_char(buf, (char)c);
            }
        }
    }
    buf_add_char(buf, '"');
}

/* ========================================================================= */
/* The channel                                                               */
/* ========================================================================= */

static Buf incoming;        /* bytes read from Vim that are not a message yet */
static size_t incoming_pos; /* how much of `incoming` has been consumed */
static int channel_closed;  /* Vim closed the channel, or stdout went away */
static int64_t next_request_id = -1; /* Vim asks jobs to use negative numbers */
static const char *plugin_id = "0";

typedef struct Queued {
    int64_t id;
    char *body;
    struct Queued *next;
} Queued;

static Queued *queue_head;
static Queued *queue_tail;

static void queue_push(int64_t id, char *body) {
    Queued *node = malloc(sizeof(Queued));
    if (node == NULL) {
        free(body);
        return;
    }
    node->id = id;
    node->body = body;
    node->next = NULL;
    if (queue_tail == NULL) {
        queue_head = node;
        queue_tail = node;
    } else {
        queue_tail->next = node;
        queue_tail = node;
    }
}

static int queue_pop(int64_t *id, char **body) {
    if (queue_head == NULL) {
        return 0;
    }
    Queued *node = queue_head;
    queue_head = node->next;
    if (queue_head == NULL) {
        queue_tail = NULL;
    }
    *id = node->id;
    *body = node->body;
    free(node);
    return 1;
}

static void send_raw(const char *data, size_t len) {
    if (channel_closed) {
        return;
    }
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(STDOUT_FILENO, data + written, len - written);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            channel_closed = 1;
            return;
        }
        written += (size_t)n;
    }
    /* Vim's JSON reader skips whitespace between messages; the newline keeps
     * the stream readable when a human is looking at it. */
    if (write(STDOUT_FILENO, "\n", 1) < 0 && errno != EINTR) {
        channel_closed = 1;
    }
}

static void send_buf(Buf *buf) {
    send_raw(buf->data, buf->len);
    buf_free(buf);
}

/* ------------------------------------------------------------------------- */
/* Reading `[number, value]` messages                                         */
/* ------------------------------------------------------------------------- */

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/*
 * Find where the JSON value starting at `start` ends. Returns the index just
 * past it, or 0 when the buffer holds only part of the value.
 */
static size_t scan_value(const char *data, size_t start, size_t end) {
    if (start >= end) {
        return 0;
    }

    if (data[start] == '"') {
        size_t i = start + 1;
        while (i < end) {
            if (data[i] == '\\') {
                i += 2;
                continue;
            }
            if (data[i] == '"') {
                return i + 1;
            }
            i++;
        }
        return 0;
    }

    if (data[start] == '[' || data[start] == '{') {
        int depth = 0;
        int in_string = 0;
        for (size_t i = start; i < end; i++) {
            char c = data[i];
            if (in_string) {
                if (c == '\\') {
                    i++;
                } else if (c == '"') {
                    in_string = 0;
                }
                continue;
            }
            if (c == '"') {
                in_string = 1;
            } else if (c == '[' || c == '{') {
                depth++;
            } else if (c == ']' || c == '}') {
                depth--;
                if (depth == 0) {
                    return i + 1;
                }
            }
        }
        return 0;
    }

    /* A number, true, false or null: runs until punctuation or whitespace. */
    size_t i = start;
    while (i < end && !is_space(data[i]) && data[i] != ',' && data[i] != ']' && data[i] != '}') {
        i++;
    }
    /* If the value runs to the very end of the buffer, more of it may still be
     * on the way, so wait for the closing bracket before deciding. */
    return i == end ? 0 : i;
}

/*
 * Pull one complete `[number, value]` message out of the buffer.
 * Returns 1 and sets `id` and a freshly allocated `body`; 0 if the buffer does
 * not hold a whole message yet.
 */
static int take_message(int64_t *id, char **body) {
    const char *data = incoming.data;
    size_t end = incoming.len;
    size_t i = incoming_pos;

    while (i < end && is_space(data[i])) {
        i++;
    }
    if (i >= end) {
        incoming_pos = i;
        return 0;
    }
    if (data[i] != '[') {
        /* Not something we can make sense of. Drop it rather than stalling. */
        fprintf(stderr, "roc-vim: ignoring unexpected input from Vim\n");
        incoming.len = 0;
        incoming_pos = 0;
        return 0;
    }
    i++;

    while (i < end && is_space(data[i])) {
        i++;
    }
    size_t number_start = i;
    if (i < end && (data[i] == '-' || data[i] == '+')) {
        i++;
    }
    while (i < end && data[i] >= '0' && data[i] <= '9') {
        i++;
    }
    if (i >= end) {
        return 0;
    }
    if (i == number_start) {
        fprintf(stderr, "roc-vim: message from Vim did not start with a number\n");
        incoming.len = 0;
        incoming_pos = 0;
        return 0;
    }
    char number[32];
    size_t number_len = i - number_start;
    if (number_len >= sizeof number) {
        number_len = sizeof number - 1;
    }
    memcpy(number, data + number_start, number_len);
    number[number_len] = '\0';

    while (i < end && is_space(data[i])) {
        i++;
    }
    if (i >= end) {
        return 0;
    }
    if (data[i] != ',') {
        fprintf(stderr, "roc-vim: malformed message from Vim\n");
        incoming.len = 0;
        incoming_pos = 0;
        return 0;
    }
    i++;

    while (i < end && is_space(data[i])) {
        i++;
    }
    size_t body_start = i;
    size_t body_end = scan_value(data, body_start, end);
    if (body_end == 0) {
        return 0;
    }

    size_t j = body_end;
    while (j < end && is_space(data[j])) {
        j++;
    }
    if (j >= end) {
        return 0;
    }
    if (data[j] != ']') {
        fprintf(stderr, "roc-vim: malformed message from Vim\n");
        incoming.len = 0;
        incoming_pos = 0;
        return 0;
    }

    size_t body_len = body_end - body_start;
    char *copy = malloc(body_len + 1);
    if (copy == NULL) {
        return 0;
    }
    memcpy(copy, data + body_start, body_len);
    copy[body_len] = '\0';

    *id = (int64_t)strtoll(number, NULL, 10);
    *body = copy;
    incoming_pos = j + 1;

    /* Reclaim the consumed prefix once it is all that is left. */
    if (incoming_pos >= incoming.len) {
        incoming.len = 0;
        incoming_pos = 0;
        if (incoming.data != NULL) {
            incoming.data[0] = '\0';
        }
    }
    return 1;
}

static int64_t now_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

typedef enum { READ_MESSAGE, READ_TIMEOUT, READ_CLOSED } ReadResult;

/* Wait for one message. A negative timeout waits indefinitely. */
static ReadResult read_message(int64_t *id, char **body, int64_t timeout_ms) {
    int64_t deadline = timeout_ms < 0 ? -1 : now_millis() + timeout_ms;

    for (;;) {
        if (take_message(id, body)) {
            return READ_MESSAGE;
        }
        if (channel_closed) {
            return READ_CLOSED;
        }

        int wait_ms = -1;
        if (deadline >= 0) {
            int64_t remaining = deadline - now_millis();
            if (remaining <= 0) {
                return READ_TIMEOUT;
            }
            wait_ms = remaining > 1000000 ? 1000000 : (int)remaining;
        }

        struct pollfd fds = { .fd = STDIN_FILENO, .events = POLLIN, .revents = 0 };
        int ready = poll(&fds, 1, wait_ms);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            channel_closed = 1;
            return READ_CLOSED;
        }
        if (ready == 0) {
            if (deadline >= 0) {
                return READ_TIMEOUT;
            }
            continue;
        }

        /* Compact the buffer before growing it. */
        if (incoming_pos > 0) {
            memmove(incoming.data, incoming.data + incoming_pos, incoming.len - incoming_pos);
            incoming.len -= incoming_pos;
            incoming_pos = 0;
        }
        buf_reserve(&incoming, 8192);
        ssize_t n = read(STDIN_FILENO, incoming.data + incoming.len, 8192);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            channel_closed = 1;
            return READ_CLOSED;
        }
        if (n == 0) {
            channel_closed = 1;
            return READ_CLOSED;
        }
        incoming.len += (size_t)n;
        incoming.data[incoming.len] = '\0';
    }
}

/*
 * Wait for the answer to request `request_id`, holding on to anything else that
 * arrives first. Returns NULL if the channel closed before the answer came.
 */
static char *await_answer(int64_t request_id) {
    for (;;) {
        int64_t id = 0;
        char *body = NULL;
        switch (read_message(&id, &body, -1)) {
        case READ_MESSAGE:
            if (id == request_id) {
                return body;
            }
            queue_push(id, body);
            break;
        case READ_TIMEOUT:
            break; /* cannot happen without a deadline */
        case READ_CLOSED:
            return NULL;
        }
    }
}

/* ========================================================================= */
/* Hosted functions                                                          */
/* ========================================================================= */

void roc_vim_ex(RocStr arg0) {
    Buf out = { 0 };
    buf_add_cstr(&out, "[\"ex\",");
    buf_add_json_str(&out, roc_str_bytes(&arg0), roc_str_len(&arg0));
    buf_add_char(&out, ']');
    send_buf(&out);
    roc_str_decref(arg0);
}

void roc_vim_normal(RocStr arg0) {
    Buf out = { 0 };
    buf_add_cstr(&out, "[\"normal\",");
    buf_add_json_str(&out, roc_str_bytes(&arg0), roc_str_len(&arg0));
    buf_add_char(&out, ']');
    send_buf(&out);
    roc_str_decref(arg0);
}

void roc_vim_send(RocStr arg0) {
    send_raw(roc_str_bytes(&arg0), roc_str_len(&arg0));
    roc_str_decref(arg0);
}

void roc_vim_reply(int64_t arg0, RocStr arg1) {
    Buf out = { 0 };
    buf_add_char(&out, '[');
    buf_add_i64(&out, arg0);
    buf_add_char(&out, ',');
    buf_add(&out, roc_str_bytes(&arg1), roc_str_len(&arg1));
    buf_add_char(&out, ']');
    send_buf(&out);
    roc_str_decref(arg1);
}

/* Wrap an answer from Vim in the envelope the Roc side expects. */
static RocStr answer_to_roc(char *body) {
    if (body == NULL) {
        return roc_str_from_cstr("{\"err\":\"Vim closed the channel\"}");
    }

    RocStr result;
    if (strcmp(body, "\"ERROR\"") == 0) {
        /* What Vim sends when it could not evaluate what we asked for. */
        result = roc_str_from_cstr("{\"err\":\"Vim could not evaluate that\"}");
    } else {
        Buf out = { 0 };
        buf_add_cstr(&out, "{\"ok\":");
        buf_add_cstr(&out, body);
        buf_add_char(&out, '}');
        result = roc_str_from(out.data, out.len);
        buf_free(&out);
    }
    free(body);
    return result;
}

RocStr roc_vim_eval(RocStr arg0) {
    int64_t request_id = next_request_id--;

    Buf out = { 0 };
    buf_add_cstr(&out, "[\"expr\",");
    buf_add_json_str(&out, roc_str_bytes(&arg0), roc_str_len(&arg0));
    buf_add_char(&out, ',');
    buf_add_i64(&out, request_id);
    buf_add_char(&out, ']');
    send_buf(&out);
    roc_str_decref(arg0);

    return answer_to_roc(await_answer(request_id));
}

RocStr roc_vim_call(RocStr arg0, RocStr arg1) {
    int64_t request_id = next_request_id--;

    Buf out = { 0 };
    buf_add_cstr(&out, "[\"call\",");
    buf_add_json_str(&out, roc_str_bytes(&arg0), roc_str_len(&arg0));
    buf_add_char(&out, ',');
    buf_add(&out, roc_str_bytes(&arg1), roc_str_len(&arg1));
    buf_add_char(&out, ',');
    buf_add_i64(&out, request_id);
    buf_add_char(&out, ']');
    send_buf(&out);
    roc_str_decref(arg0);
    roc_str_decref(arg1);

    return answer_to_roc(await_answer(request_id));
}

RocStr roc_vim_receive(int64_t arg0) {
    int64_t id = 0;
    char *body = NULL;

    if (!queue_pop(&id, &body)) {
        switch (read_message(&id, &body, arg0)) {
        case READ_MESSAGE:
            break;
        case READ_TIMEOUT:
            return roc_str_from_cstr("{\"kind\":\"timeout\"}");
        case READ_CLOSED:
            return roc_str_from_cstr("{\"kind\":\"closed\"}");
        }
    }

    Buf out = { 0 };
    buf_add_cstr(&out, "{\"kind\":\"message\",\"id\":");
    buf_add_i64(&out, id);
    buf_add_cstr(&out, ",\"body\":");
    buf_add_cstr(&out, body);
    buf_add_char(&out, '}');
    free(body);

    RocStr result = roc_str_from(out.data, out.len);
    buf_free(&out);
    return result;
}

void roc_vim_log(RocStr arg0) {
    fwrite(roc_str_bytes(&arg0), 1, roc_str_len(&arg0), stderr);
    fputc('\n', stderr);
    fflush(stderr);
    roc_str_decref(arg0);
}

RocStr roc_vim_plugin_id(void) {
    return roc_str_from_cstr(plugin_id);
}

/* ========================================================================= */

int main(int argc, char **argv) {
    /* Vim can go away at any moment; a dead channel is not worth a signal. */
    signal(SIGPIPE, SIG_IGN);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--roc-plugin-id") == 0 && i + 1 < argc) {
            plugin_id = argv[i + 1];
            i++;
        }
    }

    int32_t exit_code = roc_main();

    buf_free(&incoming);
    return (int)exit_code;
}
