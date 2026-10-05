# rv32-pipeline

**Two RISC-V processors written from scratch in SystemVerilog, a single-cycle
reference core and a five-stage pipeline with caches, a branch predictor and
an optional floating-point unit (RV32IMFD), plus the verification that shows
they are right: every instruction either core commits is checked against a
golden model, in lockstep, as it happens.**

This is a learning reimplementation of the processor project in MIT 6.1910
(Computation Structures, formerly 6.004), where students build a single-cycle
RISC-V core and then pipelined ones. Nothing here is a new idea. The point is
the engineering around the cores: an executable specification, tests at three
levels, mutations that prove the tests can fail, measured performance with the
commands that produced it, and synthesis for a real FPGA part. Everything runs
in simulation; the cores have **not** been run on a physical board.

Version 0.2.0 adds the F and D extensions to the pipelined core in the style
of a computer-architecture course project (MIT 6.5900, Berkeley CS 152): an
IEEE 754 golden model first, then the hardware, both checked against Berkeley
TestFloat, and a measurement of what the FPU buys (about 19x on
double-precision kernels) and costs (6,700 LUTs). See
[the FPU chapter of the report](docs/report.md#12-floating-point-unit-f-and-d-extensions).

[繁體中文說明](README.zh-TW.md) · [Design notes](docs/DESIGN.md) ·
[Project report (6.1910 style)](docs/report.md) · [初學者導讀](docs/導讀.zh-TW.md) ·
[Synthesis report](synth/report.md)

![Core B, the five-stage pipeline](docs/pipeline.svg)

## What is in it

* **Core A** (`rtl/core_single.sv`): single-cycle RV32IM, CPI exactly 1,
  combinational ("magic") instruction and data memory, as in the course's
  first processor lab. Diagram: [docs/single_cycle.svg](docs/single_cycle.svg).
* **Core B** (`rtl/core_pipe.sv`): IF / ID / EX / MEM / WB with forwarding from
  MEM and WB, a one-cycle load-use stall, branch resolution in EX with a
  2-cycle penalty, a predictor (128-entry BTB, 256 two-bit counters, 8-entry
  return-address stack), an iterative divider (one quotient bit per cycle, 34
  cycles in EX), precise exceptions, and
  FENCE.I that writes back the D-cache and invalidates the I-cache.
* **Floating-point unit** (`rtl/fpu.sv`, core B with the parameter `FPU=1`;
  the default `FPU=0` is the RV32IM core): all of RV32F and RV32D, the five
  rounding modes, exact exception flags, `fcsr` and `mstatus.FS`. One fused
  multiply-add datapath serves add, subtract, multiply, the four FMA
  instructions and the conversions to floating point (5 cycles); divide and
  square root are iterative, two bits per cycle (32 cycles for a double);
  FLD/FSD are two word accesses. It is a multi-cycle unit: the instruction
  waits in EX, as a divide does.
* **Caches**: 4 KiB direct-mapped I-cache; 4 KiB 2-way LRU, write-back,
  write-allocate D-cache with a store-to-load bypass; both with 16-byte lines
  and synchronous-read arrays that map to block RAM. They share one memory bus
  through an arbiter; the simulation memory answers after a configurable
  latency (default 10 cycles).
* **Golden model** (`model/rv_iss.c`): an instruction-set simulator in C that
  emits one commit record per instruction (pc, instruction, register write,
  memory write, trap). It is also a standalone simulator (`build/rvsim`).
  Its floating-point arithmetic (`model/rv_fp.c`) is written with integer
  operations only, so it gives the same bits on every host.
* **Machine mode**: Zicsr, Zifencei, ECALL/EBREAK/MRET, traps for illegal
  instructions and misaligned accesses, `mcycle`, `minstret` and ten hardware
  event counters (cache misses, mispredictions, load-use stalls, ...).
  The exact list is in [docs/DESIGN.md](docs/DESIGN.md#2-isa-what-is-and-is-not-implemented).
* **Software**: a bare-metal runtime (crt0, linker script, console and exit
  registers, printf), demo programs, CoreMark and Dhrystone fetched at
  pinned commits and built with clang/lld, and a floating-point benchmark
  built both for soft float and for the FPU.
* **Pipeline viewer**: `make pipeview` turns a simulation into a static HTML
  page showing which instruction is in which stage on every cycle.
* **Synthesis** of both cores, and of core B with the FPU, for the Spartan-7
  XC7S50 (the Real Digital Urbana board, as in the sibling project
  raycast-fpga) with Yosys.

## Results

All numbers below were measured on this machine (Apple M5, macOS, shared with
other jobs; the results are simulated cycle counts, so load does not change
them) with the commands shown.

| What | Command | Result |
|---|---|---|
| Official riscv-tests, rv32ui + rv32um + rv32uf + rv32ud (pinned commit), golden model alone | `make iss-test` | 71 / 71 pass |
| rv32ui + rv32um on core A, core B and core B with the FPU; rv32uf + rv32ud on the latter; each in lockstep with the model | `make system` | 171 / 171 pass |
| Random hazard-stressing programs, seeds 1-100, the same three cores, lockstep | `make system` | 300 / 300 pass |
| Random programs with F/D instructions, seeds 1-100, core B with the FPU, lockstep | `make system` | 100 / 100 pass |
| Both kinds, seeds 1-1000 (soak) | `make random-soak` | 4,000 / 4,000 pass |
| Golden model's IEEE 754 arithmetic against Berkeley TestFloat: every operation, both formats, five rounding modes, result and flags | `make fp-model-test` | 64,478,064 vectors, 0 mismatches |
| RTL FPU against the same TestFloat vectors, then 2,000,000 random operations against the model | `make fpu-unit` | 64,478,064 + 2,000,000, 0 mismatches |
| cocotb unit tests (ALU, register file, decoder, M unit, divider, predictor, I-cache, D-cache, CSRs) | `make unit` | 11 / 11 pass |
| One-line mutations of the RTL and of the model (16 integer, 21 floating point) | `make mutants` | 37 / 37 caught |
| `verilator --lint-only -Wall` on core A, core B, core B with the FPU, and the FPU alone | `make lint` | clean |

Benchmarks (from `make bench`, full table in [docs/benchmarks.md](docs/benchmarks.md)):

| Core | CoreMark workload, 40 iterations | Dhrystone, 500 runs |
|---|---|---|
| A, single cycle | 10,362,422 cycles, CPI 1.000, 3.86 iterations per million cycles | 519 cycles/run, 1.10 DMIPS/MHz |
| B, pipelined (default) | 12,201,403 cycles, CPI 1.177, 3.28 iterations per million cycles | 726 cycles/run, 0.78 DMIPS/MHz |
| B with an 8 KiB I-cache | 12,114,455 cycles, CPI 1.169 | 571 cycles/run, 1.00 DMIPS/MHz |

Core B: conditional branches predicted correctly 91.7 % (CoreMark) and 91.9 %
(Dhrystone); jumps and returns 97.2 % and 91.4 %. The pipelined core needs
**more** cycles than the single-cycle one (1.18x on CoreMark); it is faster only
because its clock can be much faster. Yosys' logic-only timing estimate
(`make sta`, [synth/timing.md](synth/timing.md); no routing, not timing
sign-off) puts core A's longest path at
56.2 ns (through the combinational divider) and core B's at 7.8 ns (through the
single-cycle multiplier), which would make core B roughly 6x faster on
CoreMark. [docs/report.md](docs/report.md#7-performance) explains what that
estimate does and does not mean.

Floating point (from `make fp-bench`, full table in
[docs/fp-benchmarks.md](docs/fp-benchmarks.md)): the same double-precision
kernels built for RV32IM with compiler-rt's soft-float routines and for
RV32IMFD, both on core B, cycle counts from the core's own counters. The
results are bit-identical between the two builds.

| Kernel | Soft float | Hardware FPU | Speed-up | With fused multiply-add |
|---|---:|---:|---:|---:|
| n-body, 8 bodies, 12 steps | 3,789,153 | 126,950 | 29.8x | 35.5x |
| LU factorisation, 20 x 20 | 1,502,339 | 87,627 | 17.1x | 21.7x |
| Horner polynomial | 1,263,836 | 54,159 | 23.3x | 39.4x |
| Mandelbrot | 4,865,792 | 212,639 | 22.9x | 25.9x |
| FIR filter, single precision | 2,183,820 | 224,946 | 9.7x | 13.8x |
| all five | 13,624,530 | 723,846 | **18.8x** | 23.8x |

FPU latency (cycles an instruction spends in EX): 1 for sign injection,
min/max, compares, classify and moves; 2 for float-to-integer; 5 for add,
subtract, multiply, fused multiply-add and conversions to floating point; 18
(single) or 32 (double) for divide and square root.

**These are not official scores.** The CoreMark workload validates its CRCs,
but it runs in a simulation with a notional 1 MHz clock, built from fetched
sources with our own port layer. Dhrystone is the riscv-tests version built
with clang -O2. Use the numbers only to compare the two cores with each other.

CoreMark® is a registered trademark of EEMBC®. This project runs the unmodified
CoreMark source as a workload inside a simulator; the figures above are
simulated cycle counts, not CoreMark scores, and are not certified by or
submitted to EEMBC.

Synthesis for the XC7S50 (`make synth`, [synth/report.md](synth/report.md)):

| | LUTs | Flip-flops | Block RAM | DSP48E1 | Longest path, logic only (`make sta`) |
|---|---:|---:|---:|---:|---:|
| Core A | 4,224 (13.0 %) | 960 | 0 | 4 | 56.2 ns |
| Core B | 9,305 (28.5 %) | 3,759 | 6.5 | 4 | 7.8 ns |
| Core B with the FPU | 16,047 (49.2 %) | 5,308 | 6.5 | 16 | 8.0 ns |

The FPU adds 6,742 LUTs, 1,549 flip-flops and 12 DSP blocks and the design
still fits in half the chip. The longest path with the FPU is still the
integer multiplier's, 0.2 ns longer than without because the forwarding
multiplexer in front of it maps to one more LUT level; no path inside the FPU
is longer, which is why the FPU is multi-cycle (a 53 x 53-bit multiply alone
is 10.0 ns, `make sta-blocks`). With `FPU=0` the core has the same flip-flop,
block RAM and DSP counts and the same cycle counts as before the FPU existed.

## Demo

Double-click `跑跑看.command` in Finder, or run the same steps by hand:

```
$ make build/vsim_pipe build/sw/demo.elf
$ ./build/vsim_pipe --stats build/sw/demo.elf
rv32-pipeline demo: three small programs, each measured by the core's counters

[sieve] cycles=331474 instret=150493 CPI=2.203
[sieve] icache_misses=38 dcache_accesses=27014 dcache_misses=7199 dcache_writebacks=6808 branches=38216 ...
primes below 10000: 1229 (expected 1229)

[quicksort] cycles=48173 instret=42322 CPI=1.138
[quicksort] icache_misses=19 dcache_accesses=7966 dcache_misses=1 dcache_writebacks=0 branches=7355 ...
sorted 400 numbers: ok
...
cycles 817979  instret 577714  CPI 1.4159
```

The sieve's CPI of 2.2 is the D-cache at work: its 10 KB array does not fit
in 4 KiB, so most stores evict a dirty line. When a core disagrees with the
model, the run stops at the first difference. Here is a deliberately broken
core B (MEM-to-EX forwarding removed, one of the mutants `make mutants`
builds) running the same demo. `addi sp, sp, -132` needs the `sp` that the
`auipc` just before it computed; without forwarding it reads the old value 0:

```
LOCKSTEP MISMATCH at commit 35, cycle 155
  last matching commits:
    ...
    8000007c 00002197 auipc gp, 0x2                x3 =8000207c
    80000080 f5818193 addi gp, gp, -168            x3 =80001fd4
    80000084 00100117 auipc sp, 0x100              x2 =80100084
  core : 80000088 f7c10113 addi sp, sp, -132            x2 =ffffff7c
  model: 80000088 f7c10113 addi sp, sp, -132            x2 =80100000
```

The floating-point demonstration (`make fpdemo`, also the last step of
`跑跑看.command`) runs on core B with the FPU, in lockstep like everything else:

```
$ make fpdemo
1) 0.1 + 0.2 is not 0.3
   0.1       = 0x3fb999999999999a = 0.10000000000000000555
   0.2       = 0x3fc999999999999a = 0.20000000000000001110
   0.1 + 0.2 = 0x3fd3333333333334 = 0.30000000000000004440
   0.3       = 0x3fd3333333333333 = 0.29999999999999998889
   equal? no
2) 1/3 in the five rounding modes
   nearest-even +1/3 = 0x3fd5555555555555  -1/3 = 0xbfd5555555555555
   down         +1/3 = 0x3fd5555555555555  -1/3 = 0xbfd5555555555556
   up           +1/3 = 0x3fd5555555555556  -1/3 = 0xbfd5555555555555
   ...
3) special values
   1/0       = 0x7ff0000000000000 (infinity)
   flags: divide-by-zero
   sqrt(-1)  = 0x7ff8000000000000 (NaN)
   flags: invalid
   ...
```

`make pipeview` writes `build/pipeview.html`: 200 cycles of the demo's
quicksort, one row per instruction, one column per cycle. Lower-case letters
are stalls, struck-through rows were fetched down a mispredicted path:

![Pipeline viewer](docs/media/pipeview.png)

## How the verification works

1. **Golden model.** `model/rv_iss.c` implements the ISA from the
   specification, independently of the RTL. It passes all 71 riscv-tests on
   its own.
2. **Lockstep.** Both cores expose a commit port (in the spirit of RVFI): one
   record per finished instruction. The Verilator harness (`sim/sim_main.cpp`)
   steps the model once per record and compares pc, instruction, register
   write, memory write and trap cause. Reads of cycle counters are the only
   values the model takes from the core, because they depend on timing.
3. **riscv-tests** are fetched at a pinned commit and built with our own
   `riscv_test.h` (riscv-tests expects every target to provide one). Our trap
   handler emulates misaligned loads and stores in software, as OpenSBI does,
   which is what `ma_data` needs.
4. **Random programs** (`tests/random/rvgen.py`, fixed seeds, the failing seed
   and a reproduce command are printed) concentrate on what breaks pipelines:
   dependency chains, load-use pairs, branches with work in their shadow,
   2 KiB-strided accesses that collide in one D-cache set, divide edge cases,
   CSR and counter accesses, traps, I/O, and self-modifying code behind FENCE.I.
5. **Unit tests** (cocotb on Icarus) compare each module with a Python model
   written from the ISA, including exact miss and write-back counts for the
   caches and prediction-by-prediction checks of the predictor.
6. **Floating point** is verified at the same three levels. The model's
   arithmetic is checked first against Berkeley TestFloat, whose generator
   writes operands with the expected result and flags; then the RTL FPU runs
   the same 64 million vectors in a Verilator testbench (`tests/fp/`), plus
   random operations against the model for what TestFloat does not cover
   (sign injection, min/max, classify, moves, singles that are not
   NaN-boxed). In the system, rv32uf/rv32ud and random F/D programs run in
   lockstep, and the commit record carries the f register written and the
   exception flags raised, so a wrong flag is caught on the instruction that
   raised it. The model and the RTL use different algorithms (aligned 128-bit
   add with jamming against a fixed-product adder window, long division
   against a two-bit-per-cycle recurrence), which is what makes their
   agreement mean something.
7. **Mutations** (`tools/mutate.py`) prove the tests can fail. Two of them are
   performance bugs that no functional test can see (a frozen LRU bit, stuck
   branch counters); the unit tests catch both and a CoreMark efficiency bound
   catches the second.

## Quick start

Needs Verilator 5 (tested with 5.052 and, in CI, 5.020), Icarus Verilog 12+,
Yosys (0.69 locally, 0.33 in CI), clang with the RISC-V target and ld.lld
(Homebrew LLVM on macOS, since Apple's clang has no RISC-V target), Python 3.10+
and a C++17 compiler. The first run fetches riscv-tests, CoreMark, Berkeley
SoftFloat/TestFloat and (for `make fp-bench`) LLVM's compiler-rt at pinned
commits into `build/third_party`.

```sh
brew install verilator icarus-verilog yosys llvm lld   # macOS
make venv          # once: .venv with cocotb and pytest
make test          # lint + model + TestFloat + unit + system tests, about 1.5 min
make bench         # benchmarks on both cores and five core-B variants, ~3 min
make fp-bench      # soft float against the FPU, writes build/fp-bench.md
make fpdemo        # the floating-point demonstration on core B with the FPU
make pipeview      # build/pipeview.html
make synth         # Yosys synthesis of the three builds, writes synth/report.md
make sta           # logic-only timing estimate, writes synth/timing.md
make mutants       # mutation check, ~10 min
make random-one SEED=17 CORE=pipe   # one random program with a commit trace
make random-one SEED=17 CORE=pipe_fd FP=1   # ... with F/D instructions, on the FPU core
```

Run every target from the repository root. The path may contain spaces or
non-ASCII characters; all paths in the Makefile are relative.

## Repository layout

```
rtl/            decoder, ALU, register file, CSRs, both cores, caches, predictor, divider
rtl/fp*.sv      the floating-point unit (fpu.sv and its blocks), f registers, F/D decoder
rtl/sim/        simulation tops and the memory model (not synthesisable)
model/          golden model (C): rv_iss.c, IEEE 754 arithmetic in rv_fp.c, disassembler
sim/            Verilator harness: lockstep checker, statistics, pipeline recorder
sw/runtime/     crt0, linker script, console/exit, printf, counters
sw/demo/        demo programs;  sw/bench/: CoreMark port layer, Dhrystone glue
tests/env/      riscv_test.h and trap handler for the official riscv-tests
tests/random/   random program generator;  tests/unit/: cocotb;  tests/system/: pytest
tests/fp/       TestFloat driver, model checker, Verilator testbench of the FPU
tools/          pipeline viewer, benchmark driver, mutation tool, synthesis report
synth/          Yosys scripts, synthesis wrappers, report
```

## Limitations

* Simulation only. No board bring-up, no timing closure: the delay estimates
  ignore routing and are not sign-off.
* RV32IM, plus F and D on core B: no compressed instructions, atomics,
  interrupts, user mode, virtual memory or PMP. Misaligned loads and stores
  trap (allowed by the ISA); software emulates them.
* The FPU is multi-cycle, not pipelined: one floating-point operation at a
  time, five cycles for an add or a multiply, so dense FP code runs at a CPI
  near 3. Divide and square root are radix-2, two bits per cycle. Core A has
  no FPU. No half or quad precision. FLD/FSD need a word-aligned address.
  See [report 12.7](docs/report.md#127-limitations-of-the-fpu).
* The return-address stack and the predictor are updated at EX, not
  speculatively at fetch, so back-to-back returns can mispredict.
* The memory model moves a whole 16-byte line in one beat after a fixed
  latency; real DRAM has bursts, refresh and row effects.
* Core A's memories are combinational; on an FPGA that means distributed RAM
  and a very long clock period. It is a reference, not a practical design.
* The benchmark scores are not official (see above).
* The riscv-tests rv32mi (machine-mode) suite is not run; the trap and CSR
  behaviour it would test is covered by the random programs and unit tests
  against the golden model instead.

## Related work

* **MIT 6.1910 / 6.191 Computation Structures**: students build single-cycle
  and pipelined RISC-V processors in Minispec. This repository follows that
  progression in SystemVerilog; it is not course material.
* **riscv-sodor** (UC Berkeley): educational RV32I cores with 1, 2, 3 and 5
  stages in Chisel; the closest existing project in spirit.
* **PicoRV32** (YosysHQ): a size-optimised, non-pipelined RV32IMC core in
  Verilog, about 4 cycles per instruction and 0.516 DMIPS/MHz by its README.
* **VexRiscv** (SpinalHDL): configurable 2-5+ stage pipeline; its README
  quotes 1.38 DMIPS/MHz and 2.57 CoreMark/MHz for the "full max perf"
  configuration with 8 KiB caches.
* **riscv-formal / RVFI** (YosysHQ): formal verification against an ISA model
  through a per-instruction retirement interface; the commit port here plays
  the same role for simulation, without formal proof.
* **riscv-tests** (riscv-software-src): the official ISA tests used here.
* **Berkeley SoftFloat and TestFloat** (John Hauser): the reference software
  implementation of IEEE 754 and its test-vector generator. TestFloat is the
  judge here; the golden model's arithmetic is a separate, much smaller
  integer-only implementation (two formats, 32-bit integers) checked against
  it, not a copy of SoftFloat.
* **Berkeley HardFloat** (Chisel): the FPU of Rocket and BOOM. It keeps
  numbers in a recoded format with one more exponent bit so that subnormals
  need no special handling inside the units, and is itself tested with
  TestFloat. This FPU keeps the IEEE bit patterns and deals with subnormals
  where they arise.
* **FPnew / CVFPU** (OpenHW Group, SystemVerilog): the FPU of CVA6 and
  CV32E40P, parametric in formats and in pipeline depth. The multiply-add
  datapath here follows the same textbook arrangement as its `fpnew_fma`
  (addend shifted against a fixed product in a 3p+4-bit window, add and
  multiply through the same datapath); FPnew is pipelined and multi-format,
  this one is a fixed five-step, two-format, multi-cycle unit.
* **VexRiscv's FPU** (SpinalHDL): F and optionally D; by its README it can
  produce one result per cycle for add, multiply and FMA, divides in radix 4,
  and uses 3,336 LUTs and 3,033 flip-flops for the 64/32-bit version on an
  Artix-7. It is smaller and has several times the throughput of the unit
  here, which stalls the pipeline for every operation and was written to be
  read and verified, not to compete.

Benchmark numbers from other cores were measured with other compilers,
memories and run rules, so they are context, not a ranking.

## License

MIT (see LICENSE). riscv-tests (BSD-style licence of the Regents of the
University of California), CoreMark (Apache-2.0 plus
EEMBC's trademark licence for the CoreMark name), Berkeley SoftFloat and
TestFloat (BSD 3-clause) and LLVM's compiler-rt (Apache-2.0 with LLVM
exceptions) are fetched at build time and
are not part of this repository. CoreMark® is a registered trademark of EEMBC®.
