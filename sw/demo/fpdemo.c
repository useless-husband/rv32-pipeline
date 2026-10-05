/* fpdemo: a few floating-point facts, computed by the core's own FPU.
 * Run it with `make fpdemo` (core B with the FPU, in lockstep with the
 * golden model).  docs/導讀.zh-TW.md walks through the output. */
#include "rt.h"

typedef union { double d; uint64_t u; } du;

static void hex(const char *label, double x)
{
    du v;
    v.d = x;
    printf("%s 0x%08x%08x", label, (unsigned)(v.u >> 32), (unsigned)v.u);
}

/* Print 0 <= x < 2 exactly to 20 decimal places using integer arithmetic
 * on its bits (a double is a binary fraction, so the digits do end). */
static void decimal(double x)
{
    du v;
    v.d = x;
    int e = (int)((v.u >> 52) & 0x7ff) - 1023;         /* x = 1.f * 2^e, -63 <= e <= 0 here */
    uint64_t m = (v.u & 0x000fffffffffffffull) | 0x0010000000000000ull;
    unsigned ip = e == 0 ? 1 : 0;
    uint64_t f = e == 0 ? m << 12 : (m << 11) >> (-e - 1); /* fraction scaled by 2^64 */
    printf("%u.", ip);
    for (int i = 0; i < 20; i++) {                      /* f * 10, the digit is what overflows */
        uint64_t lo = (f & 0xffffffffu) * 10, hi = (f >> 32) * 10 + (lo >> 32);
        putchar('0' + (int)(hi >> 32));
        f = (hi & 0xffffffffu) << 32 | (lo & 0xffffffffu);
    }
}

static unsigned flags(void)
{
    unsigned f;
    __asm__ volatile("frflags %0" : "=r"(f));
    return f;
}
static void clear_flags(void) { __asm__ volatile("fsflags x0"); }
static void rounding(unsigned mode) { __asm__ volatile("fsrm %0" : : "r"(mode)); }

static void show_flags(void)
{
    unsigned f = flags();
    printf("   flags:%s%s%s%s%s%s\n", f & 16 ? " invalid" : "", f & 8 ? " divide-by-zero" : "",
           f & 4 ? " overflow" : "", f & 2 ? " underflow" : "", f & 1 ? " inexact" : "", f ? "" : " none");
    clear_flags();
}

/* volatile so the compiler leaves the arithmetic to the FPU */
static volatile double one = 1.0, three = 3.0, zero = 0.0, tenth = 0.1, fifth = 0.2, big = 1e308, tiny = 1e-308;

int main(void)
{
    printf("1) 0.1 + 0.2 is not 0.3\n");
    double s = tenth + fifth;
    hex("   0.1       =", tenth); printf(" = "); decimal(tenth); printf("\n");
    hex("   0.2       =", fifth); printf(" = "); decimal(fifth); printf("\n");
    hex("   0.1 + 0.2 =", s);     printf(" = "); decimal(s);     printf("\n");
    hex("   0.3       =", 0.3);   printf(" = "); decimal(0.3);   printf("\n");
    printf("   equal? %s\n", s == 0.3 ? "yes" : "no");
    clear_flags();

    printf("2) 1/3 in the five rounding modes\n");
    static const char *const names[5] = {"nearest-even", "toward zero ", "down        ", "up          ", "nearest-away"};
    for (unsigned m = 0; m < 5; m++) {
        rounding(m);
        double t = one / three, n = -one / three;
        printf("   %s ", names[m]); hex("+1/3 =", t); hex("  -1/3 =", n); printf("\n");
    }
    rounding(0);
    show_flags();

    printf("3) special values\n");
    hex("   1/0       =", one / zero); printf(" (infinity)\n"); show_flags();
    hex("   0/0       =", zero / zero); printf(" (NaN)\n"); show_flags();
    hex("   sqrt(-1)  =", __builtin_sqrt(-one)); printf(" (NaN)\n"); show_flags();
    hex("   1e308*10  =", big * 10.0); printf(" (infinity)\n"); show_flags();
    hex("   1e-308/1e10 =", tiny / 1e10); printf(" (subnormal)\n"); show_flags();
    hex("   sqrt(2)   =", __builtin_sqrt(one + one)); printf(" = "); decimal(__builtin_sqrt(one + one)); printf("\n");
    show_flags();

    printf("4) how long one operation keeps the pipeline waiting\n");
    static volatile double x = 1.2345, y = 6.789, r;
    static const char *const ops[4] = {"add ", "mul ", "div ", "sqrt"};
    for (int k = 0; k < 5; k++) {
        uint64_t c0 = rdcycle64();
        for (int i = 0; i < 100; i++) {
            switch (k) {
            case 0: r = x + y; break;
            case 1: r = x * y; break;
            case 2: r = x / y; break;
            case 3: r = __builtin_sqrt(x); break;
            default: r = x; break;
            }
        }
        unsigned c = (unsigned)(rdcycle64() - c0);
        static unsigned base;
        if (k == 4) {
            base = c;
            printf("   (the loop alone: %u cycles for 100 rounds)\n", base);
        } else {
            printf("   %s: %u cycles for 100 rounds\n", ops[k], c);
        }
    }
    (void)r;
    return 0;
}
