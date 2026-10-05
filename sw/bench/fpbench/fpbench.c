/* fpbench: floating-point workloads for comparing software floating point
 * (RV32IM, compiler-rt's routines) with the hardware FPU (RV32IMFD).
 *
 * The same source is built three ways (see the Makefile):
 *   soft      -march=rv32im   -mabi=ilp32                      (library calls)
 *   hard      -march=rv32imfd -mabi=ilp32d -ffp-contract=off   (F/D instructions)
 *   hard-fma  -march=rv32imfd -mabi=ilp32d -ffp-contract=fast  (a*b+c fused)
 * "soft" and "hard" perform exactly the same IEEE operations, so their
 * checksums (the bit patterns of the results) must be identical; fused
 * multiply-adds round once instead of twice, so "hard-fma" may differ in
 * the last bits.  tools/fpbench.py runs them and checks that.
 *
 * Kernels (all self-written for this project):
 *   nbody    8 bodies under gravity, leapfrog steps  (mul, add, div, sqrt)
 *   lu       LU factorisation with partial pivoting and solve, 20 x 20
 *   poly     Horner evaluation of a degree-12 polynomial
 *   mandel   Mandelbrot escape counts (mul, add, compare, branch)
 *   fir      32-tap FIR filter in single precision
 *   ops      one operation per array element, to give a cost per operation
 *
 * Each kernel prints "[name] cycles=... instret=..." from the core's own
 * counters and "name checksum=...". */
#include "rt.h"

typedef union { double d; uint64_t u; } du;
typedef union { float f; uint32_t u; } fu;

static uint64_t bits(double x) { du v; v.d = x; return v.u; }
static uint32_t bitsf(float x) { fu v; v.f = x; return v.u; }

static uint64_t t0_cycles, t0_instret;
static void begin(void) { t0_cycles = rdcycle64(); t0_instret = rdinstret64(); }
static void end(const char *name)
{
    uint64_t c = rdcycle64() - t0_cycles, i = rdinstret64() - t0_instret;
    printf("[%s] cycles=%u instret=%u\n", name, (unsigned)c, (unsigned)i);
}
static void checksum(const char *name, uint64_t v)
{
    printf("%s checksum=%08x%08x\n", name, (unsigned)(v >> 32), (unsigned)v);
}

/* Square root.  With the FPU it is the FSQRT.D instruction.  Without it, a
 * correctly rounded digit-by-digit routine on the bit pattern (the kind of
 * code a soft-float math library has), so both builds give the same bits. */
#ifdef __riscv_flen
static inline double my_sqrt(double x) { return __builtin_sqrt(x); }
#else
static double my_sqrt(double x)
{
    du v;
    v.d = x;
    uint64_t frac = v.u & 0x000fffffffffffffull;
    int e = (int)((v.u >> 52) & 0x7ff);
    if (v.u >> 63 || e == 0 || e == 0x7ff)
        return x;   /* zero, subnormal, negative, infinity, NaN: not used by the kernels */
    uint64_t m = frac | 0x0010000000000000ull;   /* 1.f as a 53-bit integer */
    e -= 1023;
    if (e & 1) { m <<= 1; e -= 1; }              /* even exponent, m in [1,4) */
    /* root of m * 2^(2*54-52): 55 result bits (53 + guard + round) */
    uint64_t root = 0, rem = 0;
    for (int i = 0; i < 55; i++) {
        unsigned two = i < 27 ? (unsigned)(m >> (52 - 2 * i)) & 3 : 0;
        rem = rem << 2 | two;
        uint64_t trial = root << 2 | 1;
        root <<= 1;
        if (rem >= trial) { rem -= trial; root |= 1; }
    }
    /* round to nearest even: bit 1 is the guard, bit 0 and the remainder are sticky */
    uint64_t sig = root >> 2;
    unsigned g = (unsigned)(root >> 1) & 1, s = (unsigned)(root & 1) | (rem != 0);
    if (g && (s || (sig & 1))) sig++;
    if (sig >> 53) { sig >>= 1; e += 2; }
    v.u = (uint64_t)(e / 2 + 1023) << 52 | (sig & 0x000fffffffffffffull);
    return v.d;
}
#endif

/* ------------------------------------------------------------- nbody */
#define NB 8
#define NB_STEPS 12
static double px[NB], py[NB], pz[NB], vx[NB], vy[NB], vz[NB], mass[NB];

static uint64_t nbody(void)
{
    for (int i = 0; i < NB; i++) {
        px[i] = 1.0 + 0.37 * i;  py[i] = -0.5 + 0.21 * i * i;  pz[i] = 0.1 * (i % 3) - 0.3 * i;
        vx[i] = 0.01 * (i - 3);  vy[i] = 0.02 * (2 - i);       vz[i] = 0.005 * i;
        mass[i] = 1.0 + 0.125 * i;
    }
    const double dt = 0.01, eps = 1e-3;
    for (int s = 0; s < NB_STEPS; s++) {
        for (int i = 0; i < NB; i++) {
            double ax = 0, ay = 0, az = 0;
            for (int j = 0; j < NB; j++) {
                if (j == i) continue;
                double dx = px[j] - px[i], dy = py[j] - py[i], dz = pz[j] - pz[i];
                double r2 = dx * dx + dy * dy + dz * dz + eps;
                double inv = mass[j] / (r2 * my_sqrt(r2));
                ax += dx * inv; ay += dy * inv; az += dz * inv;
            }
            vx[i] += dt * ax; vy[i] += dt * ay; vz[i] += dt * az;
        }
        for (int i = 0; i < NB; i++) {
            px[i] += dt * vx[i]; py[i] += dt * vy[i]; pz[i] += dt * vz[i];
        }
    }
    uint64_t h = 0;
    for (int i = 0; i < NB; i++)
        h = (h << 7 | h >> 57) ^ bits(px[i]) ^ bits(py[i]) * 3 ^ bits(pz[i]) * 5;
    return h;
}

/* ---------------------------------------------------------------- lu */
#define LN 20
static double A[LN][LN], bvec[LN], xvec[LN];

static uint64_t lu(void)
{
    uint32_t seed = 12345;
    for (int i = 0; i < LN; i++) {
        for (int j = 0; j < LN; j++) {
            seed = seed * 1664525u + 1013904223u;
            A[i][j] = (double)(int)(seed >> 8) * (1.0 / 8388608.0) - 1.0 + (i == j ? 4.0 : 0.0);
        }
        bvec[i] = 1.0 + 0.5 * i;
    }
    for (int k = 0; k < LN; k++) {
        int p = k;
        double best = A[k][k] < 0 ? -A[k][k] : A[k][k];
        for (int i = k + 1; i < LN; i++) {
            double a = A[i][k] < 0 ? -A[i][k] : A[i][k];
            if (a > best) { best = a; p = i; }
        }
        if (p != k) {
            for (int j = 0; j < LN; j++) { double t = A[k][j]; A[k][j] = A[p][j]; A[p][j] = t; }
            double t = bvec[k]; bvec[k] = bvec[p]; bvec[p] = t;
        }
        double inv = 1.0 / A[k][k];
        for (int i = k + 1; i < LN; i++) {
            double f = A[i][k] * inv;
            for (int j = k + 1; j < LN; j++)
                A[i][j] -= f * A[k][j];
            bvec[i] -= f * bvec[k];
        }
    }
    for (int i = LN - 1; i >= 0; i--) {
        double s = bvec[i];
        for (int j = i + 1; j < LN; j++)
            s -= A[i][j] * xvec[j];
        xvec[i] = s / A[i][i];
    }
    uint64_t h = 0;
    for (int i = 0; i < LN; i++)
        h = (h << 9 | h >> 55) ^ bits(xvec[i]);
    return h;
}

/* -------------------------------------------------------------- poly */
static uint64_t poly(void)
{
    static const double c[13] = {0.5, -1.25, 0.75, 2.0, -0.3, 0.125, 1.5, -0.875, 0.0625, 3.0, -2.5, 0.2, 1.0};
    uint64_t h = 0;
    double x = -1.0;
    for (int n = 0; n < 400; n++) {
        double y = c[12];
        for (int k = 11; k >= 0; k--)
            y = y * x + c[k];
        h = (h << 5 | h >> 59) ^ bits(y);
        x += 0.005;
    }
    return h;
}

/* ------------------------------------------------------------ mandel */
static uint64_t mandel(void)
{
    uint64_t h = 0;
    for (int iy = 0; iy < 12; iy++) {
        for (int ix = 0; ix < 24; ix++) {
            double cr = -2.0 + ix * (3.0 / 24), ci = -1.0 + iy * (2.0 / 12), zr = 0, zi = 0;
            int it = 0;
            while (it < 40) {
                double zr2 = zr * zr, zi2 = zi * zi;
                if (zr2 + zi2 > 4.0) break;
                zi = 2.0 * zr * zi + ci;
                zr = zr2 - zi2 + cr;
                it++;
            }
            h = h * 31 + (unsigned)it;
        }
    }
    return h;
}

/* --------------------------------------------------------------- fir */
#define TAPS 32
#define FIR_N 400
static float taps[TAPS], sig[FIR_N + TAPS];

static uint64_t fir(void)
{
    for (int i = 0; i < TAPS; i++)
        taps[i] = (float)(i - 15) * 0.03125f + 0.01f * (float)(i % 5);
    uint32_t seed = 777;
    for (int i = 0; i < FIR_N + TAPS; i++) {
        seed = seed * 1664525u + 1013904223u;
        sig[i] = (float)(int)(seed >> 16) * (1.0f / 32768.0f) - 1.0f;
    }
    uint64_t h = 0;
    for (int n = 0; n < FIR_N; n++) {
        float acc = 0;
        for (int k = 0; k < TAPS; k++)
            acc += taps[k] * sig[n + k];
        h = (h << 3 | h >> 61) ^ bitsf(acc);
    }
    return h;
}

/* --------------------------------------------------------------- ops */
#define ON 64
#define OREP 8
static double oa[ON], ob[ON], oc[ON];
static int oi[ON];

#define OPLOOP(name, expr)                                          \
    static __attribute__((noinline)) void name(void)                \
    {                                                               \
        for (int r = 0; r < OREP; r++)                              \
            for (int i = 0; i < ON; i++)                            \
                expr;                                               \
    }
OPLOOP(op_copy, oc[i] = oa[i])
OPLOOP(op_add, oc[i] = oa[i] + ob[i])
OPLOOP(op_mul, oc[i] = oa[i] * ob[i])
OPLOOP(op_div, oc[i] = oa[i] / ob[i])
OPLOOP(op_sqrt, oc[i] = my_sqrt(oa[i]))
OPLOOP(op_cmp, oi[i] = oa[i] < ob[i])
OPLOOP(op_i2d, oc[i] = (double)oi[i])
OPLOOP(op_d2i, oi[i] = (int)ob[i])

static uint64_t ops(void)
{
    static void (*const fn[])(void) = {op_copy, op_add, op_mul, op_div, op_sqrt, op_cmp, op_i2d, op_d2i};
    static const char *const names[] = {"copy", "add", "mul", "div", "sqrt", "cmp", "i2d", "d2i"};
    uint64_t h = 0;
    for (int i = 0; i < ON; i++) {
        oa[i] = 1.0 + 0.3125 * i + 1.0 / (i + 3);
        ob[i] = 7.5 - 0.11 * i;
        oi[i] = i * 37 - 500;
    }
    fn[0]();    /* warm the caches */
    for (unsigned k = 0; k < sizeof fn / sizeof fn[0]; k++) {
        uint64_t c0 = rdcycle64();
        fn[k]();
        uint64_t c = rdcycle64() - c0;
        /* cycles per element in hundredths (two loads, the operation, one store, the loop) */
        printf("[op_%s] per_element_x100=%u\n", names[k], (unsigned)(c * 100 / (ON * OREP)));
        for (int i = 0; i < ON; i++)
            h = (h << 1 | h >> 63) ^ bits(oc[i]) ^ (uint32_t)oi[i];
    }
    return h;
}

int main(void)
{
    static uint64_t (*const kernel[])(void) = {nbody, lu, poly, mandel, fir};
    static const char *const names[] = {"nbody", "lu", "poly", "mandel", "fir"};
#ifdef __riscv_flen
    printf("fpbench: hardware floating point (RV32IMFD)\n");
#else
    printf("fpbench: software floating point (RV32IM)\n");
#endif
    begin();
    for (unsigned k = 0; k < sizeof kernel / sizeof kernel[0]; k++) {
        uint64_t c0 = rdcycle64(), i0 = rdinstret64();
        uint64_t h = kernel[k]();
        uint64_t c = rdcycle64() - c0, i = rdinstret64() - i0;
        printf("[%s] cycles=%u instret=%u\n", names[k], (unsigned)c, (unsigned)i);
        checksum(names[k], h);
    }
    end("total");
    checksum("ops", ops());
    return 0;
}
