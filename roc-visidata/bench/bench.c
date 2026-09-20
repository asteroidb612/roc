/*
 * What it costs to run a Roc plugin inside a host, measured three ways:
 *
 *   open   - compiling the plugin in-process (the startup-latency question)
 *   map    - one bulk call over N values (the derived-column question)
 *   handle - one event, the way a command dispatch goes
 *
 * Build: see build.sh. Everything here talks to libroc_embed through
 * roc_embed.h, exactly as roc-visidata's engine would.
 */

#include "roc_embed.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

/* ---- the one hosted function the platform declares ---------------------- */

static long log_calls;

static void roc_str_decref(RocStr s) {
    uint8_t *bytes = s.bytes;
    intptr_t *refcount;

    /* small strings carry their bytes inline; nothing to free */
    if (bytes == NULL || (((uint8_t *)&s)[sizeof(RocStr) - 1u] & 0x80u) != 0) return;
    refcount = ((intptr_t *)bytes) - 1;
    if (*refcount == INTPTR_MIN) return;  /* a literal in static data */
    *refcount -= 1;
    if (*refcount == 0) free((uint8_t *)bytes - sizeof(size_t));
}

void roc_bench_log(RocStr message) {
    log_calls += 1;
    roc_str_decref(message);
}

static void *resolve_hosted(void *ctx, const char *symbol, size_t len) {
    (void)ctx;
    if (len == strlen("roc_bench_log") && memcmp(symbol, "roc_bench_log", len) == 0) {
        return (void *)roc_bench_log;
    }
    return NULL;
}

/* ---- building what the entrypoints take -------------------------------- */

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
    bytes = base + sizeof(size_t);
    ((intptr_t *)bytes)[-1] = 1;
    memcpy(bytes, data, len);
    out.bytes = bytes;
    out.capacity_or_alloc_ptr = len << 1;
    out.length = len;
    return out;
}

/* A List(F64) laid out the way Roc expects: a refcount word, then elements. */
static RocList roc_list_f64(const double *values, size_t count) {
    RocList out;
    uint8_t *base = malloc(sizeof(size_t) + count * sizeof(double));
    uint8_t *elements = base + sizeof(size_t);

    ((intptr_t *)elements)[-1] = 1;
    memcpy(elements, values, count * sizeof(double));
    out.elements = elements;
    out.length = count;
    out.capacity_or_alloc_ptr = count << 1;
    return out;
}


/* A List(Str). Short strings live inline in the 24-byte RocStr, which is the
 * common case for a column of names and the cheapest one for Roc. */
static RocList roc_list_str(char **texts, size_t count) {
    RocList out;
    uint8_t *base = malloc(sizeof(size_t) + count * sizeof(RocStr));
    uint8_t *elements = base + sizeof(size_t);
    RocStr *slots = (RocStr *)elements;

    ((intptr_t *)elements)[-1] = 1;
    for (size_t k = 0; k < count; k++) slots[k] = roc_str_from(texts[k], strlen(texts[k]));
    out.elements = elements;
    out.length = count;
    out.capacity_or_alloc_ptr = count << 1;
    return out;
}

static void roc_list_free(RocList list) {
    if (list.elements == NULL) return;
    if (((intptr_t *)list.elements)[-1] == INTPTR_MIN) return;
    free(list.elements - sizeof(size_t));
}

/* ---- the benchmark ------------------------------------------------------ */

static void report(const char *label, double *samples, int count, double per) {
    double best = samples[0], total = 0;
    int i;

    for (i = 0; i < count; i++) {
        if (samples[i] < best) best = samples[i];
        total += samples[i];
    }
    printf("%-22s best %9.3f ms   mean %9.3f ms", label, best, total / count);
    if (per > 0) printf("   %8.1f ns/element (best)", best * 1e6 / per);
    printf("\n");
}

int main(int argc, char **argv) {
    const char *path;
    size_t n;
    int opens, iters, i;
    double *samples, *input;
    void *program = NULL;
    char *error = NULL;
    int map_ord, handle_ord;

    if (argc < 2) {
        fprintf(stderr, "usage: %s <app.roc> [n] [iters] [opens]\n", argv[0]);
        return 2;
    }
    path = argv[1];
    n = argc > 2 ? (size_t)strtoul(argv[2], NULL, 10) : 1000000;
    iters = argc > 3 ? atoi(argv[3]) : 5;
    opens = argc > 4 ? atoi(argv[4]) : 3;

    printf("== %s   n=%zu ==\n", path, n);

    /* 1. Compiling the plugin in-process. */
    samples = malloc(sizeof(double) * (size_t)opens);
    for (i = 0; i < opens; i++) {
        double t0 = now_ms();
        void *p = roc_embed_open(path, strlen(path), NULL, resolve_hosted, &error);
        samples[i] = now_ms() - t0;
        if (p == NULL) {
            fprintf(stderr, "open failed: %s\n", error ? error : "(no message)");
            return 1;
        }
        if (i == opens - 1) program = p; else roc_embed_close(p);
    }
    report("open (compile)", samples, opens, 0);
    free(samples);

    map_ord = roc_embed_entrypoint(program, "roc_bench_map", strlen("roc_bench_map"));
    handle_ord = roc_embed_entrypoint(program, "roc_bench_handle", strlen("roc_bench_handle"));
    if (map_ord < 0 || handle_ord < 0) {
        fprintf(stderr, "entrypoints missing (map=%d handle=%d)\n", map_ord, handle_ord);
        return 1;
    }

    /* 2. One event, the way a command dispatch goes. */
    samples = malloc(sizeof(double) * (size_t)iters);
    for (i = 0; i < iters; i++) {
        unsigned char *args = calloc(1, roc_embed_args_size(program, handle_ord));
        RocStr event = roc_str_from("{\"event\":\"command:bench\"}", 25);
        RocStr out;
        double t0;

        memcpy(args + roc_embed_arg_offset(program, handle_ord, 0), &event, sizeof event);
        t0 = now_ms();
        if (roc_embed_call(program, handle_ord, args, &out, &error) != 0) {
            fprintf(stderr, "handle failed: %s\n", error ? error : "(no message)");
            return 1;
        }
        samples[i] = now_ms() - t0;
        roc_str_decref(out);
        free(args);
    }
    report("handle (one event)", samples, iters, 0);
    free(samples);

    /* 3. The bulk path: one call over the whole column. */
    input = malloc(sizeof(double) * n);
    for (size_t k = 0; k < n; k++) input[k] = (double)k * 0.5;


    /* A plain C loop over the same data: what compiled Roc is aiming at, and
     * the ceiling nothing on this boundary can beat. */
    samples = malloc(sizeof(double) * (size_t)iters);
    for (i = 0; i < iters; i++) {
        double *out = malloc(sizeof(double) * n);
        double t0 = now_ms();
        for (size_t k = 0; k < n; k++) out[k] = input[k] * 2.5 + 1.0;
        samples[i] = now_ms() - t0;
        if (out[n - 1] == 12345.6789) printf("");
        free(out);
    }
    report("C loop (ceiling)", samples, iters, (double)n);
    free(samples);

    samples = malloc(sizeof(double) * (size_t)iters);
    for (i = 0; i < iters; i++) {
        double t0 = now_ms();
        RocList in = roc_list_f64(input, n);
        samples[i] = now_ms() - t0;
        roc_list_free(in);
    }
    report("marshal in (build)", samples, iters, (double)n);

    for (i = 0; i < iters; i++) {
        unsigned char *args = calloc(1, roc_embed_args_size(program, map_ord));
        RocList in = roc_list_f64(input, n);
        RocList out;
        double t0;

        memcpy(args + roc_embed_arg_offset(program, map_ord, 0), &in, sizeof in);
        t0 = now_ms();
        if (roc_embed_call(program, map_ord, args, &out, &error) != 0) {
            fprintf(stderr, "map failed: %s\n", error ? error : "(no message)");
            return 1;
        }
        samples[i] = now_ms() - t0;
        /* read the result back, as a host filling a column would */
        {
            double sink = 0;
            double *elements = (double *)out.elements;
            for (size_t k = 0; k < out.length; k++) sink += elements[k];
            if (sink == 12345.6789) printf("");  /* keep it */
        }
        roc_list_free(out);
        free(args);
    }
    report("map (interpreted)", samples, iters, (double)n);
    free(samples);


    /* 4. The same bulk path over a column of text. */
    {
        int strs_ord = roc_embed_entrypoint(program, "roc_bench_map_strs",
                                            strlen("roc_bench_map_strs"));
        if (strs_ord >= 0) {
            size_t sn = n > 1000000 ? 1000000 : n;  /* strings are 24B each */
            char **texts = malloc(sizeof(char *) * sn);

            for (size_t k = 0; k < sn; k++) {
                texts[k] = malloc(16);
                snprintf(texts[k], 16, "row%zu", k % 100000);
            }

            samples = malloc(sizeof(double) * (size_t)iters);
            for (i = 0; i < iters; i++) {
                double t0 = now_ms();
                RocList in = roc_list_str(texts, sn);
                samples[i] = now_ms() - t0;
                roc_list_free(in);
            }
            report("marshal in (strs)", samples, iters, (double)sn);

            for (i = 0; i < iters; i++) {
                unsigned char *args = calloc(1, roc_embed_args_size(program, strs_ord));
                RocList in = roc_list_str(texts, sn);
                RocList out;
                double t0;

                memcpy(args + roc_embed_arg_offset(program, strs_ord, 0), &in, sizeof in);
                t0 = now_ms();
                if (roc_embed_call(program, strs_ord, args, &out, &error) != 0) {
                    fprintf(stderr, "map_strs failed: %s\n", error ? error : "(no message)");
                    return 1;
                }
                samples[i] = now_ms() - t0;
                {
                    RocStr *slots = (RocStr *)out.elements;
                    for (size_t k = 0; k < out.length; k++) roc_str_decref(slots[k]);
                }
                roc_list_free(out);
                free(args);
            }
            report("map strs (interpreted)", samples, iters, (double)sn);
            free(samples);
            for (size_t k = 0; k < sn; k++) free(texts[k]);
            free(texts);
        }
    }

    printf("hosted log calls: %ld\n", log_calls);
    roc_embed_close(program);
    return 0;
}
