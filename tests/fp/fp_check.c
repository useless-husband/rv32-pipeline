/* fp_check: compare the golden model's arithmetic (model/rv_fp.c) with
 * Berkeley TestFloat.  Reads `testfloat_gen` output on stdin: one test per
 * line, operands, expected result and expected flags, all in hex.
 *
 *   testfloat_gen -rnear_even -tininessafter -exact f64_add | fp_check f64_add near_even
 *
 * Prints the number of vectors checked; exit status 1 on any difference. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rv_fp.h"

static int rounding(const char *s)
{
    static const char *names[] = {"near_even", "minMag", "min", "max", "near_maxMag"};
    for (int i = 0; i < 5; i++)
        if (!strcmp(s, names[i])) return i;
    fprintf(stderr, "fp_check: unknown rounding mode %s\n", s);
    exit(2);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: fp_check <testfloat function> <rounding mode> < vectors\n");
        return 2;
    }
    const char *fn = argv[1];
    int rm = rounding(argv[2]);
    int d = !strncmp(fn, "f64_", 4) || !strcmp(fn, "i32_to_f64") || !strcmp(fn, "ui32_to_f64");
    const char *op = fn[0] == 'f' ? fn + 4 : fn;
    int nin = !strcmp(op, "mulAdd") ? 3 : (!strcmp(op, "add") || !strcmp(op, "sub") || !strcmp(op, "mul") ||
              !strcmp(op, "div") || !strcmp(op, "eq") || !strcmp(op, "lt") || !strcmp(op, "le")) ? 2 : 1;
    uint64_t n = 0, bad = 0, v[5];
    char line[256];

    while (fgets(line, sizeof line, stdin)) {
        char *p = line;
        int k = 0;
        for (; k < 5; k++) {
            char *end;
            v[k] = strtoull(p, &end, 16);
            if (end == p) break;
            p = end;
        }
        if (k != nin + 2) {
            fprintf(stderr, "fp_check: malformed line: %s", line);
            return 2;
        }
        uint64_t want = v[nin], got;
        uint32_t wantfl = (uint32_t)v[nin + 1], fl = 0;
        if (!strcmp(op, "add")) got = rvfp_add(d, v[0], v[1], rm, &fl);
        else if (!strcmp(op, "sub")) got = rvfp_sub(d, v[0], v[1], rm, &fl);
        else if (!strcmp(op, "mul")) got = rvfp_mul(d, v[0], v[1], rm, &fl);
        else if (!strcmp(op, "div")) got = rvfp_div(d, v[0], v[1], rm, &fl);
        else if (!strcmp(op, "sqrt")) got = rvfp_sqrt(d, v[0], rm, &fl);
        else if (!strcmp(op, "mulAdd")) got = rvfp_fma(d, v[0], v[1], v[2], 0, 0, rm, &fl);
        else if (!strcmp(op, "eq")) got = (uint64_t)rvfp_eq(d, v[0], v[1], &fl);
        else if (!strcmp(op, "lt")) got = (uint64_t)rvfp_lt(d, v[0], v[1], &fl);
        else if (!strcmp(op, "le")) got = (uint64_t)rvfp_le(d, v[0], v[1], &fl);
        else if (!strcmp(op, "to_i32")) got = rvfp_f2i(d, v[0], 0, rm, &fl);
        else if (!strcmp(op, "to_ui32")) got = rvfp_f2i(d, v[0], 1, rm, &fl);
        else if (!strcmp(op, "to_f64")) got = rvfp_f2f(1, v[0], rm, &fl);
        else if (!strcmp(op, "to_f32")) got = rvfp_f2f(0, v[0], rm, &fl);
        else if (!strncmp(op, "i32_to_", 7)) got = rvfp_i2f(d, (uint32_t)v[0], 0, rm, &fl);
        else if (!strncmp(op, "ui32_to_", 8)) got = rvfp_i2f(d, (uint32_t)v[0], 1, rm, &fl);
        else {
            fprintf(stderr, "fp_check: unknown function %s\n", fn);
            return 2;
        }
        n++;
        if (got != want || fl != wantfl) {
            if (bad++ < 5)
                fprintf(stderr, "MISMATCH %s %s: %s  got %" PRIx64 " flags %02x\n", fn, argv[2], line, got, fl);
        }
    }
    printf("%-12s %-11s %10" PRIu64 " vectors, %" PRIu64 " mismatches\n", fn, argv[2], n, bad);
    return bad != 0;
}
