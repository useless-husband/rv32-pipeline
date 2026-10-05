// Unit testbench for the RTL floating-point unit (rtl/fpu.sv), Verilator.
//
// Two modes, both drive the unit exactly as the pipeline does (start held,
// wait for done, ack):
//
//   fpu_tb <testfloat function> <rounding mode> < vectors
//       Berkeley TestFloat vectors on stdin (see tests/fp/testfloat.py):
//       result and flags must match the vector.  The fused multiply-add
//       vectors also exercise FMSUB/FNMSUB/FNMADD by flipping operand signs.
//   fpu_tb --random N SEED
//       N random operations of every kind, including the ones TestFloat has
//       no vectors for (sign injection, FMIN/FMAX, FCLASS, FMV), with
//       operands biased toward special values; the reference is the golden
//       model's arithmetic (model/rv_fp.c).
//
// Prints the vector count, mismatches and the latency range in clock cycles.
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

#include "Vfpu.h"
#include "verilated.h"

extern "C" {
#include "rv_fp.h"
}

double sc_time_stamp() { return 0; }

enum { ADD, SUB, MUL, MADD, MSUB, NMSUB, NMADD, DIV, SQRT, F2F, I2F, IU2F, F2I, F2IU, SGNJ, SGNJN, SGNJX,
       MIN, MAX, EQ, LT, LE, CLASS, MVXW, MVWX, NOPS };
static const char *kOpNames[NOPS] = {"add", "sub", "mul", "madd", "msub", "nmsub", "nmadd", "div", "sqrt",
    "f2f", "i2f", "iu2f", "f2i", "f2iu", "sgnj", "sgnjn", "sgnjx", "min", "max", "eq", "lt", "le", "class",
    "mvxw", "mvwx"};

struct Tb {
    std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    std::unique_ptr<Vfpu> top{new Vfpu(ctx.get())};
    uint64_t lat_min[NOPS], lat_max[NOPS];

    Tb()
    {
        for (int i = 0; i < NOPS; i++) { lat_min[i] = ~0ull; lat_max[i] = 0; }
        top->start = 0; top->kill = 0; top->ack = 0;
        top->rst = 1;
        for (int i = 0; i < 3; i++) tick();
        top->rst = 0;
    }
    void tick()
    {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }
    // returns the number of clock cycles the operation spent "in EX"
    uint64_t run(int op, int dbl, int rm, uint64_t a, uint64_t b, uint64_t c, uint32_t ia, uint64_t *res,
                 uint32_t *ires, uint32_t *fl)
    {
        top->op = op; top->dbl = dbl; top->rm = rm;
        top->a = a; top->b = b; top->c = c; top->ia = ia;
        top->start = 1;
        uint64_t cycles = 1;
        top->eval();
        while (!top->done) {
            tick();
            if (++cycles > 400) { std::fprintf(stderr, "fpu_tb: no done after 400 cycles (op %d)\n", op); std::exit(2); }
        }
        *res = top->result; *ires = top->iresult; *fl = top->flags;
        top->ack = 1;
        tick();
        top->ack = 0; top->start = 0;
        top->eval();
        if (cycles < lat_min[op]) lat_min[op] = cycles;
        if (cycles > lat_max[op]) lat_max[op] = cycles;
        return cycles;
    }
};

static uint64_t box(int d, uint64_t v) { return d ? v : (0xffffffff00000000ull | (uint32_t)v); }
static uint64_t flip(int d, uint64_t v) { return v ^ (1ull << (d ? 63 : 31)); }

static int rounding(const char *s)
{
    static const char *names[] = {"near_even", "minMag", "min", "max", "near_maxMag"};
    for (int i = 0; i < 5; i++)
        if (!std::strcmp(s, names[i])) return i;
    std::fprintf(stderr, "fpu_tb: unknown rounding mode %s\n", s);
    std::exit(2);
}

static int testfloat(Tb &tb, const char *fn, const char *mode)
{
    int rm = rounding(mode);
    std::string f(fn);
    int d = f.rfind("f64_", 0) == 0;
    std::string op = f[0] == 'f' ? f.substr(4) : f;
    int nin = op == "mulAdd" ? 3 : (op == "add" || op == "sub" || op == "mul" || op == "div" || op == "eq" ||
                                    op == "lt" || op == "le") ? 2 : 1;
    uint64_t n = 0, bad = 0, v[5], lmin = ~0ull, lmax = 0;
    char line[256];
    while (std::fgets(line, sizeof line, stdin)) {
        char *p = line;
        int k = 0;
        for (; k < 5; k++) {
            char *end;
            v[k] = std::strtoull(p, &end, 16);
            if (end == p) break;
            p = end;
        }
        if (k != nin + 2) { std::fprintf(stderr, "fpu_tb: malformed line: %s", line); return 2; }
        uint64_t want = v[nin], res = 0, got, cyc;
        uint32_t wantfl = (uint32_t)v[nin + 1], ires = 0, fl = 0;
        bool is_int = false;
        if (op == "add") cyc = tb.run(ADD, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl);
        else if (op == "sub") cyc = tb.run(SUB, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl);
        else if (op == "mul") cyc = tb.run(MUL, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl);
        else if (op == "div") cyc = tb.run(DIV, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl);
        else if (op == "sqrt") cyc = tb.run(SQRT, d, rm, box(d, v[0]), 0, 0, 0, &res, &ires, &fl);
        else if (op == "mulAdd") {
            // a*b+c = a*b-(-c) = -((-a)*b)+c = -((-a)*b)-(-c): one vector, four instructions in turn
            switch (n & 3) {
            case 0: cyc = tb.run(MADD, d, rm, box(d, v[0]), box(d, v[1]), box(d, v[2]), 0, &res, &ires, &fl); break;
            case 1: cyc = tb.run(MSUB, d, rm, box(d, v[0]), box(d, v[1]), box(d, flip(d, v[2])), 0, &res, &ires, &fl); break;
            case 2: cyc = tb.run(NMSUB, d, rm, box(d, flip(d, v[0])), box(d, v[1]), box(d, v[2]), 0, &res, &ires, &fl); break;
            default: cyc = tb.run(NMADD, d, rm, box(d, flip(d, v[0])), box(d, v[1]), box(d, flip(d, v[2])), 0, &res, &ires, &fl); break;
            }
        }
        else if (op == "eq") { is_int = true; cyc = tb.run(EQ, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl); }
        else if (op == "lt") { is_int = true; cyc = tb.run(LT, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl); }
        else if (op == "le") { is_int = true; cyc = tb.run(LE, d, rm, box(d, v[0]), box(d, v[1]), 0, 0, &res, &ires, &fl); }
        else if (op == "to_i32") { is_int = true; cyc = tb.run(F2I, d, rm, box(d, v[0]), 0, 0, 0, &res, &ires, &fl); }
        else if (op == "to_ui32") { is_int = true; cyc = tb.run(F2IU, d, rm, box(d, v[0]), 0, 0, 0, &res, &ires, &fl); }
        else if (op == "to_f64") { d = 1; cyc = tb.run(F2F, 1, rm, box(0, v[0]), 0, 0, 0, &res, &ires, &fl); }
        else if (op == "to_f32") { d = 0; cyc = tb.run(F2F, 0, rm, v[0], 0, 0, 0, &res, &ires, &fl); }
        else if (op.rfind("i32_to_", 0) == 0) { d = op == "i32_to_f64"; cyc = tb.run(I2F, d, rm, 0, 0, 0, (uint32_t)v[0], &res, &ires, &fl); }
        else if (op.rfind("ui32_to_", 0) == 0) { d = op == "ui32_to_f64"; cyc = tb.run(IU2F, d, rm, 0, 0, 0, (uint32_t)v[0], &res, &ires, &fl); }
        else { std::fprintf(stderr, "fpu_tb: unknown function %s\n", fn); return 2; }
        got = is_int ? ires : res;
        if (!is_int) want = box(d, want);
        n++;
        if (cyc < lmin) lmin = cyc;
        if (cyc > lmax) lmax = cyc;
        if (got != want || fl != wantfl) {
            if (bad++ < 5)
                std::fprintf(stderr, "MISMATCH %s %s: %s  got %" PRIx64 " flags %02x\n", fn, mode, line, got, fl);
        }
    }
    std::printf("%-12s %-11s %10" PRIu64 " vectors, %" PRIu64 " mismatches, %" PRIu64 "-%" PRIu64 " cycles\n", fn, mode,
                n, bad, lmin, lmax);
    return bad != 0;
}

// ----------------------------------------------------------------- random
static uint64_t rng_state;
static uint64_t rnd()
{ // xorshift64*
    rng_state ^= rng_state >> 12; rng_state ^= rng_state << 25; rng_state ^= rng_state >> 27;
    return rng_state * 0x2545F4914F6CDD1Dull;
}

// a value of format d, biased toward the interesting ones
static uint64_t rnd_fp(int d)
{
    int p = d ? 53 : 24, eb = d ? 11 : 8;
    uint64_t emax = (1ull << eb) - 1, sign = rnd() & 1, e, frac = rnd() & ((1ull << (p - 1)) - 1);
    switch (rnd() % 12) {
    case 0: e = 0; frac = 0; break;                                   // zero
    case 1: e = emax; frac = 0; break;                                // infinity
    case 2: e = emax; frac |= 1ull << (p - 2); break;                 // quiet NaN
    case 3: e = emax; frac = (frac & ~(1ull << (p - 2))) | 1; break;  // signaling NaN
    case 4: e = 0; if (rnd() & 1) frac >>= rnd() % (p - 1); frac |= 1; break; // subnormal
    case 5: e = 1 + rnd() % 3; break;                                 // just above subnormal
    case 6: e = emax - 1 - rnd() % 3; break;                          // near overflow
    case 7: e = emax / 2 + (rnd() % 5) - 2; frac = (rnd() & 1) ? 0 : (1ull << (p - 1)) - 1; break; // powers of two, all ones
    case 8: e = emax / 2 + (rnd() % 64) - 32; frac &= ~((1ull << (rnd() % (p - 1))) - 1); break; // few low bits
    default: e = rnd() % (emax - 1) + 1; break;
    }
    return sign << (d ? 63 : 31) | e << (p - 1) | frac;
}

static int random_ops(Tb &tb, uint64_t count, uint64_t seed)
{
    rng_state = seed * 0x9E3779B97F4A7C15ull + 1;
    uint64_t bad = 0, per_op[NOPS] = {0};
    for (uint64_t i = 0; i < count; i++) {
        int op = (int)(rnd() % NOPS), d = (int)(rnd() & 1), rm = (int)(rnd() % 5);
        uint64_t a = rnd_fp(d), b = (rnd() % 8 == 0) ? a : rnd_fp(d), c = rnd_fp(d);
        if (rnd() % 16 == 0) b = flip(d, a);
        uint32_t ia = (rnd() % 4 == 0) ? (uint32_t)(rnd() % 3) - 1u : (uint32_t)rnd() >> (rnd() % 32);
        if (rnd() & 1) ia = 0u - ia;
        uint64_t ra = box(d, a), rb = box(d, b), rc = box(d, c);
        // sometimes a single that is not NaN-boxed: it must read as the canonical NaN
        if (!d && rnd() % 32 == 0) { ra = a | (rnd() << 32 & 0x7fffffff00000000ull); a = 0x7fc00000u; }
        if (!d && rnd() % 32 == 0) { rb = b | (rnd() << 32 & 0x7fffffff00000000ull); b = 0x7fc00000u; }
        uint64_t want = 0, res = 0, sb = 1ull << (d ? 63 : 31);
        uint32_t wfl = 0, ires = 0, fl = 0, iwant = 0;
        bool is_int = false;
        switch (op) {
        case ADD: want = rvfp_add(d, a, b, rm, &wfl); break;
        case SUB: want = rvfp_sub(d, a, b, rm, &wfl); break;
        case MUL: want = rvfp_mul(d, a, b, rm, &wfl); break;
        case MADD: want = rvfp_fma(d, a, b, c, 0, 0, rm, &wfl); break;
        case MSUB: want = rvfp_fma(d, a, b, c, 0, 1, rm, &wfl); break;
        case NMSUB: want = rvfp_fma(d, a, b, c, 1, 0, rm, &wfl); break;
        case NMADD: want = rvfp_fma(d, a, b, c, 1, 1, rm, &wfl); break;
        case DIV: want = rvfp_div(d, a, b, rm, &wfl); break;
        case SQRT: want = rvfp_sqrt(d, a, rm, &wfl); break;
        case F2F: { // source format is the other one
            uint64_t src = rnd_fp(!d);
            ra = box(!d, src);
            want = rvfp_f2f(d, src, rm, &wfl);
            break;
        }
        case I2F: want = rvfp_i2f(d, ia, 0, rm, &wfl); break;
        case IU2F: want = rvfp_i2f(d, ia, 1, rm, &wfl); break;
        case F2I: is_int = true; iwant = rvfp_f2i(d, a, 0, rm, &wfl); break;
        case F2IU: is_int = true; iwant = rvfp_f2i(d, a, 1, rm, &wfl); break;
        case SGNJ: want = (a & ~sb) | (b & sb); break;
        case SGNJN: want = (a & ~sb) | (~b & sb); break;
        case SGNJX: want = a ^ (b & sb); break;
        case MIN: want = rvfp_minmax(d, a, b, 0, &wfl); break;
        case MAX: want = rvfp_minmax(d, a, b, 1, &wfl); break;
        case EQ: is_int = true; iwant = (uint32_t)rvfp_eq(d, a, b, &wfl); break;
        case LT: is_int = true; iwant = (uint32_t)rvfp_lt(d, a, b, &wfl); break;
        case LE: is_int = true; iwant = (uint32_t)rvfp_le(d, a, b, &wfl); break;
        case CLASS: is_int = true; iwant = rvfp_classify(d, a); break;
        case MVXW: is_int = true; d = 0; iwant = (uint32_t)ra; break;
        default: d = 0; want = ia; break; // MVWX
        }
        tb.run(op, d, rm, ra, rb, rc, ia, &res, &ires, &fl);
        per_op[op]++;
        bool ok = fl == wfl && (is_int ? ires == iwant : res == box(d, want));
        if (!ok && bad++ < 5)
            std::fprintf(stderr, "MISMATCH %s d=%d rm=%d a=%016" PRIx64 " b=%016" PRIx64 " c=%016" PRIx64
                         " ia=%08x: got %016" PRIx64 "/%08x flags %02x, want %016" PRIx64 "/%08x flags %02x\n",
                         kOpNames[op], d, rm, ra, rb, rc, ia, res, ires, fl, box(d, want), iwant, wfl);
    }
    std::printf("| Operation | Runs | Cycles in EX |\n|---|---:|---:|\n");
    for (int i = 0; i < NOPS; i++) {
        if (tb.lat_min[i] == tb.lat_max[i])
            std::printf("| %s | %" PRIu64 " | %" PRIu64 " |\n", kOpNames[i], per_op[i], tb.lat_min[i]);
        else
            std::printf("| %s | %" PRIu64 " | %" PRIu64 "-%" PRIu64 " |\n", kOpNames[i], per_op[i], tb.lat_min[i], tb.lat_max[i]);
    }
    std::printf("\nrandom seed %" PRIu64 ": %" PRIu64 " vectors, %" PRIu64 " mismatches\n", seed, count, bad);
    return bad != 0;
}

int main(int argc, char **argv)
{
    Tb tb;
    int rc;
    if (argc == 4 && !std::strcmp(argv[1], "--random"))
        rc = random_ops(tb, std::strtoull(argv[2], nullptr, 0), std::strtoull(argv[3], nullptr, 0));
    else if (argc == 3)
        rc = testfloat(tb, argv[1], argv[2]);
    else {
        std::fprintf(stderr, "usage: fpu_tb <testfloat function> <rounding mode> < vectors\n"
                             "       fpu_tb --random N SEED\n");
        return 2;
    }
    tb.top->final();
    return rc;
}
