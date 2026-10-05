# Design project report: a single-cycle and a pipelined RV32IM processor

*Written in the format of an MIT 6.1910 (Computation Structures) design
project report. This is an independent learning reimplementation; it is not
course material and is not affiliated with MIT.*

## 1. Goal

Build two processors for the same instruction set and measure the difference:

* **Core A**, single cycle: the reference, easy to reason about, CPI = 1.
* **Core B**, five-stage pipeline with hazard handling, a branch predictor and
  caches in front of a slow memory: the realistic design.

Then show that both are correct, with evidence a reviewer can rerun, and
explain where core B's cycles go. Every number in this report comes from a
command in the repository (section 10 lists them) and was measured on an Apple
M5 running macOS 27, shared with other jobs (the numbers are simulated cycle
counts, so host load does not affect them).

## 2. Instruction set

RV32IM + Zicsr + Zifencei, machine mode only, synchronous exceptions only.
The precise list (CSRs, exception causes, `mtval` values, the platform's memory
map and I/O registers) is in [DESIGN.md section 2](DESIGN.md#2-isa-what-is-and-is-not-implemented).
Left out: C, A, interrupts, U/S modes, virtual memory, PMP, hardware
support for misaligned accesses (they trap; software emulates them).
Since version 0.2.0 core B can also be built with the F and D extensions
(parameter `FPU = 1`); that work has its own chapter, section 12, and the
sections before it describe the RV32IM cores.

## 3. Core A: the single-cycle datapath

![Single-cycle datapath](single_cycle.svg)

Everything happens between two clock edges: fetch from a combinational
instruction memory, decode, read two registers, compute (ALU, branch
comparator, combinational multiplier and divider, CSR access), access a
combinational data memory, and write the result back at the edge. The next PC
is selected from pc+4, the branch/JAL target, the JALR target, `mtvec` (trap)
or `mepc` (MRET). Core A itself is about 200 lines of SystemVerilog on top of
the shared modules (decoder, ALU, register file, load/store aligner, CSR file).

## 4. Core B: the pipelined datapath

![Five-stage pipeline](pipeline.svg)

**Stages.** IF reads the I-cache and asks the predictor for the next PC; ID
decodes, reads registers and detects hazards; EX forwards operands, computes,
resolves branches, raises exceptions and accesses CSRs; MEM accesses the
D-cache; WB writes the register file and reports the instruction on the commit
port.

**Data hazards.** EX takes operands from MEM, then WB, then the register file
(which itself bypasses the WB write to a same-cycle read in ID). A value loaded
in MEM is not available until the end of that cycle, so an instruction that
uses it immediately waits one cycle in ID (one bubble). CSR instructions wait
in ID until the rest of the pipeline is empty, so that `minstret` reads are
exact and CSR writes are visible to later instructions without extra paths.

**Control hazards.** Branches and jumps resolve in EX. Each instruction
carries the PC the fetch stage predicted after it; if EX computes a different
next PC (misprediction, trap, MRET), IF and ID are flushed and fetch restarts
at the right place: a 2-cycle penalty. FENCE.I waits in MEM until the D-cache
has written back its dirty lines and the I-cache has invalidated itself, then
flushes IF, ID and EX and refetches.

**Structural hazards.** The iterative divider holds EX for 34 cycles; both
caches share one memory bus through an arbiter that favours the D-cache.

**One non-obvious case.** When MEM stalls on a cache miss, the instruction in
WB retires and WB empties. An instruction waiting in EX that was getting an
operand forwarded from WB would lose it, so EX rewrites its operand registers
with the forwarded values every cycle it is held. Removing that line is one of
the mutants in section 6.3; the tests catch it.

The stall and flush logic reduces to six signals; the table is in
[DESIGN.md 5.1](DESIGN.md#51-stall-and-flush-rules).

## 5. Caches and branch predictor

**I-cache**: 4 KiB, direct mapped, 16-byte lines. **D-cache**: 4 KiB, two
ways, one LRU bit per set, write-back, write-allocate, 16-byte lines; I/O
addresses bypass it. Both keep tags and data in synchronous-read arrays
(block RAM on the FPGA), so the pipeline gives them the address one cycle
ahead and the hit check happens in the stage itself. A miss writes back a
dirty victim if needed, refills the line in one bus transaction, re-reads the
arrays for one cycle and then hits. Because the data array is written at the
same clock edge at which the next access reads it, a one-entry bypass merges a
store's bytes into the following read. Details and the alternatives considered
are in [DESIGN.md 6](DESIGN.md#6-caches-and-memory-bus).

**Memory.** The simulation memory accepts one request at a time and answers
after a fixed latency (10 cycles by default), moving a whole line at once.

**Predictor.** 128-entry BTB (full tags; target and kind), 256 two-bit
counters, 8-entry return-address stack using the ISA's `ra`/`t0` hints. All
are updated in EX when an instruction resolves, never on the wrong path.

## 6. Verification

### 6.1 Strategy

| Level | What | Reference | Where |
|---|---|---|---|
| Module | ALU, register file, decoder, M unit, divider, predictor, I-cache, D-cache, CSR file | Python models written from the ISA; exact counts for caches and predictor | `tests/unit` (cocotb, Icarus) |
| ISA | 50 official riscv-tests (rv32ui, rv32um) | the tests check themselves, and run in lockstep | `tests/system/test_riscv_tests.py` |
| Hazards | random programs, 100 fixed seeds, about 3,000 instructions of program text each (6,000-8,000 executed) | lockstep with the golden model | `tests/random/rvgen.py`, `tests/system/test_random.py` |
| Programs | demo, CoreMark, Dhrystone | lockstep, plus CoreMark's own CRC checks | `make bench`, `tests/system/test_perf.py` |
| The tests themselves | 16 one-line mutations | each must make a test fail | `tools/mutate.py` |

**Lockstep.** The golden model (`model/rv_iss.c`) is an independent C
implementation of the ISA. The harness steps it once for every instruction a
core commits and compares pc, instruction, register write, memory write and
trap. Timing-dependent counter reads are the only values the model adopts from
the core. The first difference stops the run and prints the last eight
matching instructions, which makes failures quick to diagnose:

```
LOCKSTEP MISMATCH at commit 35, cycle 155
  last matching commits:
    80000068 00000d93 addi s11, zero, 0            x27=00000000
    ...
    80000084 00100117 auipc sp, 0x100              x2 =80100084
  core : 80000088 f7c10113 addi sp, sp, -132            x2 =ffffff7c
  model: 80000088 f7c10113 addi sp, sp, -132            x2 =80100000
```

(Core B with MEM-to-EX forwarding removed, running the demo program: the
`addi` needs the `sp` computed by the `auipc` right before it.)

**riscv-tests environment.** riscv-tests expects each target to supply its own
`riscv_test.h`. Ours (`tests/env`) sets up machine mode, reports through the
EXIT register and installs a trap handler that emulates misaligned loads and
stores byte by byte, which is what `ma_data` requires on hardware that traps
on misaligned accesses. Any other trap fails the test.

**Random programs** always terminate (forward branches, counted loops) and
aim at the hard cases: sources drawn mostly from the last four destinations,
loads followed by their use, stores followed by loads of the same word, one
to four instructions (including loads, stores, divides and CSR accesses) in
every branch shadow, accesses at 2 KiB strides that land in one D-cache set,
divide by 0 / -1 / INT_MIN, reads of `minstret` and of timing-dependent
counters, writes to `mscratch`/`mepc`/`mcause`/`mtval`, ECALL, EBREAK, illegal
encodings, misaligned accesses and jumps (the handler skips the instruction),
console I/O, and instructions patched in memory and made visible with
FENCE.I. Seed 3 on core B, for example, produces 338 D-cache misses with 204
dirty write-backs, 245 branch mispredictions, 38 traps and 14 FENCE.I in 7,451
instructions.

### 6.2 Results

| Suite | Command | Result |
|---|---|---|
| riscv-tests on the golden model alone (rv32ui, um, uf, ud) | `make iss-test` | 71 / 71 |
| riscv-tests in lockstep: rv32ui + um on core A, core B and core B with the FPU; rv32uf + ud on the latter | `make system` | 171 / 171 |
| random integer programs, seeds 1-100, the same three cores | `make system` | 300 / 300 |
| random programs, seeds 1-1000, three cores, plus 1000 F/D programs on the FPU core | `make random-soak` | 4,000 / 4,000 |
| CoreMark efficiency bounds on core B | `make system` | pass |
| cocotb unit tests | `make unit` | 11 / 11 |
| `verilator --lint-only -Wall` | `make lint` | clean |
| mutations | `make mutants` | 37 / 37 caught (16 below, 21 F/D ones in section 12.6) |

The floating-point tests (TestFloat, rv32uf/rv32ud, F/D random programs) are
listed in section 12.6.

### 6.3 Mutation results

Each mutant is a one-line change. "random" counts how many of 30 random
programs failed; "perf" is the CoreMark run of `test_perf.py`, which fails
on a lockstep mismatch as well as on an efficiency bound. Generated by
`make mutants` ([full table](mutants.md)):

| Mutant | What it breaks | Caught by |
|---|---|---|
| `fwd_mem` | no MEM->EX forwarding for rs1 | 50 riscv-tests, 30 random, perf |
| `fwd_wb` | no WB->EX forwarding for rs2 | 10 riscv-tests, 30 random, perf |
| `no_load_use` | load-use hazard not detected | 6 riscv-tests, 30 random, perf |
| `no_id_flush` | ID not flushed on a misprediction | 1 riscv-test, 30 random, perf |
| `no_operand_refresh` | EX loses a forwarded operand while held | 1 riscv-test, 30 random, perf |
| `dirty_lost` | store hit does not set the dirty bit | unit, 1 riscv-test, 30 random, perf |
| `no_store_bypass` | load after a store to the same line reads stale data | unit, 5 riscv-tests, 30 random |
| `lru_frozen` | LRU bit not updated on hits (performance only) | unit test only |
| `fencei_no_inval` | FENCE.I leaves stale instructions in the I-cache | unit, 30 random |
| `bht_stuck` | counters never move toward taken (performance only) | unit, perf |
| `sra_logical` | SRA shifts in zeros | unit, 4 riscv-tests and 30 random on each core, perf |
| `rem_sign` | REM sign wrong for negative dividends | unit, 1 riscv-test, 29 random |
| `branch_legal` | reserved branch encodings accepted | unit, 29 random on each core |
| `mepc_unmasked` | `mepc` keeps its low two bits | unit, 14 random on each core |
| `single_bltu` | core A compares BLTU as signed | 1 riscv-test, 30 random |
| `model_mulhsu` | golden model: MULHSU treats rs2 as signed | riscv-tests on the model |

What this taught: the official `fence_i` test does not notice a missing
I-cache invalidation (the lines it patches were never cached), but the random
programs do. The first run of this table had `branch_legal` and
`mepc_unmasked` caught only by unit tests; the random generator was extended
(reserved encodings, `mepc`/`mcause`/`mtval` writes) until system tests
caught them too. Performance bugs are invisible to lockstep by design, which
is why the predictor and cache unit tests check exact counts and why CoreMark
has efficiency bounds; `lru_frozen` changes CoreMark's miss count too little
to cross them, so only its unit test catches it.

## 7. Performance

### 7.1 Method

`make bench` builds CoreMark (40 iterations, performance-run seeds, 2 KB of
data) and Dhrystone (riscv-tests version, 500 runs) with clang -O2 for rv32im,
runs them on both cores in lockstep, and reads the core's own counters around
each benchmark's timed region. Core B also runs in five variants (predictor
off, no return stack, 8 KiB I-cache, memory latency 1 and 30). Full table:
[benchmarks.md](benchmarks.md).

### 7.2 Results

| Configuration | CoreMark-workload cycles | CPI | iterations per million cycles | Dhrystone cycles/run | CPI | DMIPS/MHz |
|---|---:|---:|---:|---:|---:|---:|
| A: single cycle | 10,362,422 | 1.000 | 3.86 | 519 | 1.000 | 1.10 |
| B: default | 12,201,403 | 1.177 | 3.28 | 726 | 1.398 | 0.78 |
| B: predictor off | 14,587,065 | 1.408 | 2.74 | 896 | 1.726 | 0.64 |
| B: no return stack | 12,226,219 | 1.180 | 3.27 | 732 | 1.410 | 0.78 |
| B: 8 KiB I-cache | 12,114,455 | 1.169 | 3.30 | 571 | 1.100 | 1.00 |
| B: memory latency 1 | 12,061,923 | 1.164 | 3.32 | 617 | 1.188 | 0.92 |
| B: memory latency 30 | 12,511,363 | 1.207 | 3.20 | 969 | 1.866 | 0.59 |

Core B (default) predicts 91.7 % of CoreMark's conditional branches and
97.2 % of its jumps and returns; for Dhrystone 91.9 % and 91.4 %. I-cache hit
rate 99.85 % (CoreMark) and 97.71 % (Dhrystone); D-cache hit rate above
99.99 % and 99.98 %.

**These are not official scores.** CoreMark validates its CRCs ("Correct
operation validated") and, counting one cycle as one microsecond, runs 12.2
"seconds", past its 10-second minimum; but the clock is notional, the
platform is a simulation, and the result has not been submitted to EEMBC.
Dhrystone is compiled with -O2 by clang, with the riscv-tests harness. The
figures are for comparing the two cores and the variants with each other.

### 7.3 Where core B's cycles go

CoreMark, default configuration: 1,838,966 cycles more than instructions.

| Cause | Events | Cycles | Share |
|---|---:|---:|---:|
| load-use bubbles | 1,276,618 | 1,276,618 | 69 % |
| conditional branch mispredictions (2 cycles each) | 175,508 | 351,016 | 19 % |
| I-cache misses (memory latency + about 2 cycles each) | 15,469 | about 185,000 | 10 % |
| jump and return mispredictions | 6,389 | 12,778 | 0.7 % |
| D-cache misses, CSR drains, divides | | about 13,000 | 0.7 % |

CoreMark is dominated by load-use pairs: its list traversal and state machine
load a value and use it right away, and the compiler does not schedule for
this pipeline. Dhrystone is different: of its 103,393 extra cycles about 70 %
are I-cache misses (6,075, twelve per run: its hot code does not fit a 4 KiB
direct-mapped cache without conflicts). The 8 KiB variant removes them
(I-cache hit rate 99.97 %, CPI 1.10). The latency variants confirm the
accounting: going from latency 10 to 1 saves 54,609 cycles on Dhrystone, and
9 cycles times its 6,107 misses and write-backs predicts 54,963.

The predictor matters most: turning it off costs 20 % on CoreMark (CPI 1.177
to 1.408) and 23 % on Dhrystone. The return stack lifts Dhrystone's jump
prediction from 78.9 % to 91.4 %. During development the BTB had only 32
entries; over the whole Dhrystone program that predicted 46 % of jumps and
92.0 % of branches, and 128 entries raised them to 95 % and 94.9 %: the
counters were fine, the BTB was too small.

### 7.4 Single cycle against pipelined

Core B needs **more** cycles than core A: 1.18x on CoreMark, 1.40x on
Dhrystone. The pipeline can only win through its clock. Without place and
route there is no clock frequency to measure, so the best available evidence
is Yosys' static timing pass over its 7-series cell delay models (`make sta`,
[synth/timing.md](../synth/timing.md)):
logic delay only, no routing, which on an FPGA is often half of a real path.

| | Longest path (logic only) | Ends at |
|---|---:|---|
| Core A | 56.2 ns | register-file write data, through the 32-step combinational divider |
| Core B | 7.8 ns | EX result, through the 33x33 multiplier (DSP48E1 cascade) and the result mux |

With those delays CoreMark would take 581.9 ms on core A and 95.8 ms on core
B, about 6.1x; Dhrystone about 5.1x. Treat this as an illustration of why
pipelines exist rather than as a measurement: core A's path is dominated by a
divider no practical single-cycle design would keep, its memories are outside
the analysed netlist (a real single-cycle core would add an instruction-memory
and a data-memory access to the same path), and routing is missing for both.

## 8. Resource usage

Yosys `synth_xilinx` for the Spartan-7 XC7S50 (`make synth`,
[full report](../synth/report.md)). Each core is synthesised behind a wrapper
that exposes only its memory interface, so the commit port and viewer probes
do not count.

| | LUTs | Flip-flops | Block RAM (36 Kb) | DSP48E1 |
|---|---:|---:|---:|---:|
| Core A | 4,224 (13.0 %) | 960 | 0 | 4 |
| Core B | 9,305 (28.5 %) | 3,759 | 6.5 | 4 |
| Core B with the FPU (section 12) | 16,047 (49.2 %) | 5,308 | 6.5 | 16 |

In core B the D-cache is the largest block (about 3,100 LUTs: 128-bit line
multiplexers for two ways, the store bypass and the write-back buffer),
followed by the predictor (about 1,800 LUTs: the BTB in distributed RAM plus
the read multiplexer of the packed counter table) and the CSR file (about
1,500 LUTs, mostly twelve 64-bit counters). The cache arrays
use 6.5 block RAMs. Both cores fit comfortably; neither has been placed,
routed or run on a board.

## 9. Challenges and lessons

* **Block RAM changes the pipeline.** Synchronous-read arrays mean the cache
  must see the address a cycle early. Getting that "next address" right in
  every stall and redirect case was the most delicate part of core B, and it
  is why the cache unit tests drive the caches exactly as the pipeline does.
* **Read-during-write.** A store hit and the next access touch the same array
  at the same clock edge. The bypass that fixes it is easy to forget; the
  mutant that removes it fails the unit test, five riscv-tests and every
  random program.
* **Stalls interact.** A miss in MEM changes what EX can forward from WB
  (section 4). Reasoning about each stage in isolation is not enough; random
  programs are what exercise the combinations.
* **Measure before tuning.** The first predictor numbers looked like a counter
  problem; the per-event counters showed it was BTB capacity.
* **A test suite has to prove it can fail.** The mutation run found two holes
  in the system tests (now closed) and one in the official riscv-tests.
* **Old tools in CI.** Keeping to a subset that Ubuntu's Verilator 5.020,
  Icarus 12 and Yosys 0.33 accept meant no packages, structs or casts to
  parameter widths.

## 10. Reproducing

```sh
make venv        # once
make test        # lint, golden model, unit and system tests (about 20 s)
make mutants     # mutation table (about 10 min)
make bench       # benchmark table (about 3 min)
make fp-bench    # floating-point benchmark: soft float against the FPU
make synth       # synthesis report;  make sta for the delay estimate
make pipeview    # pipeline viewer page
```

Pinned third-party sources: riscv-tests `bcffa2b3188b040c611f90dc0b6e422f54775a09`,
CoreMark `1f483d5b8316753a742cbf5590caf5bd0a4e4777`, Berkeley SoftFloat
`a0c6494cdc11865811dec815d5c0049fba9d82a8` and TestFloat
`a9c849f1b0eb0264b626d9686ffae167d996e3be`, LLVM compiler-rt (soft-float
routines of the benchmark's baseline) `85ac560262434c9ccfc0c183ec22d4138ed647fb`. Tools used here:
Verilator 5.052, Icarus Verilog 13.0, Yosys 0.69, clang and lld 23.1.

## 11. Future work

* **Put it to use.** Connect core B to the sibling project raycast-fpga's
  video pipeline on the Urbana board: the CPU would run the game logic and
  write the map and player state that the hardware raycaster reads, replacing
  its fixed-function player FSM. That needs a memory-mapped register block, an
  FPGA memory controller instead of the simulation model, and real timing
  closure.
* **Shorten the critical path**: a two-stage multiplier, then place and route
  with a vendor or open flow to get a real Fmax.
* **Reduce the load-use cost**, 69 % of CoreMark's stall cycles: compiler
  scheduling for this pipeline, or a faster load path.
* **Better prediction**: gshare or a tournament predictor, and a speculative
  return stack with repair.
* **Out-of-order execution**: a small Tomasulo-style core with a reorder
  buffer. The commit port and the lockstep checker work at retirement, so they
  would carry over unchanged.
* **Formal verification** of core B with riscv-formal, through an RVFI wrapper
  around the commit port.
* **Interrupts**: a timer interrupt would make the CSR file complete enough to
  run the machine-mode riscv-tests (rv32mi).

## 12. Floating-point unit (F and D extensions)

Added in version 0.2.0. Core B has a parameter `FPU`: 0 (the default) is the
RV32IM core of the sections above; 1 adds the F and D extensions (RV32IMFD).
Core A stays RV32IM: a single-cycle double-precision divide or fused
multiply-add would be a combinational path several times longer than the one
that already makes core A impractical, so floating point is a core B feature.
Every technique here is standard; the closest published designs are named in
the README's Related Work.

### 12.1 What had to be decided

IEEE 754 leaves several things to the implementation and RISC-V fixes most of
them. The ones that shaped the design:

* **Formats and registers.** binary32 and binary64 in 32 registers of 64
  bits. A single lives in the low half with all ones above it ("NaN boxing");
  a register that is read as a single and is not boxed is the canonical NaN.
* **NaNs.** Every NaN result is the canonical quiet NaN (payloads are not
  propagated). Signaling NaN inputs raise *invalid*.
* **Rounding.** All five modes (nearest-even, toward zero, down, up,
  nearest-away), chosen per instruction or through `frm`. A reserved mode is
  an illegal instruction.
* **Flags.** The five accrued flags of `fflags` must be exact, including
  *inexact*, and underflow uses **tininess after rounding** (the result is
  tiny if it would still be below the smallest normal number had the exponent
  range been unbounded). No trap is ever taken on a flag.
* **`mstatus.FS`.** Off after reset: every F/D instruction and the three FP
  CSRs trap until software turns it on. It becomes *dirty* when an f register
  or `fcsr` changes (the rule both the model and the RTL implement: a write
  to an f register, a raised flag, or a CSR write to `fflags`/`frm`/`fcsr`).
* **FLD/FSD on a 32-bit data path.** Section 12.4.

### 12.2 The golden model first

`model/rv_fp.c` is the arithmetic the RTL is judged against, so it was written
and validated before any hardware. It uses integer operations only (no
`float`, `double` or `<math.h>`), which makes its results identical on every
host. Each finite operand is unpacked into a sign, an exponent and a 64-bit
significand with the leading one at bit 63. Each operation produces an exact
result, or an exact prefix plus a *sticky* bit that says "something nonzero
was cut off", and hands it to one function, `round_pack()`, the only place
that rounds, detects overflow and underflow and builds the bit pattern.

| Operation | How the model computes it |
|---|---|
| add, subtract | align the smaller operand in a 128-bit window (shifted-out bits jam into the last bit), add or subtract, renormalise |
| multiply | 64 x 64 -> 128-bit product from four 32-bit partial products |
| fused multiply-add | the exact 128-bit product and the addend go through the same aligned add; one rounding |
| divide | long division, one quotient bit per step, 64 bits; a nonzero remainder is the sticky bit |
| square root | digit-by-digit (two radicand bits in, one root bit out), 64 bits; remainder is the sticky bit |
| conversions | shift into place and round with the same rule; invalid float-to-integer conversions saturate |

It was then checked against **Berkeley TestFloat**: `testfloat_gen` (built at
a pinned commit with SoftFloat's RISC-V specialisation, never committed)
writes operands, the expected result and the expected flags, and
`tests/fp/fp_check.c` compares. `make fp-model-test`:

| Functions | Formats | Rounding modes | TestFloat level | Vectors |
|---|---|---:|---:|---:|
| add, sub, mul, div | f32, f64 | 5 | 1 | 1,858,560 |
| eq, lt, le | f32, f64 | 1 (they do not round) | 1 | 278,784 |
| mulAdd | f32, f64 | 5 | 1 | 61,332,480 |
| sqrt | f32, f64 | 5 | 2 | 174,560 |
| to_i32, to_ui32 | f32, f64 | 5 | 2 | 349,120 |
| i32/ui32 to f32/f64 | | 5 | 2 | 310,000 |
| f32 to f64, f64 to f32 | | 5 | 2 | 174,560 |
| **total** | | | | **64,478,064, 0 mismatches** |

One-operand functions use level 2 because their level 1 has only a few
hundred cases. TestFloat has no vectors for sign injection, FMIN/FMAX,
FCLASS and the FMV moves; those are covered by the official riscv-tests
(`fmin`, `fclass`, `move`, `recoding`) on the model and on the core.

### 12.3 The hardware units

`rtl/fpu.sv` is a multi-cycle unit: the pipeline starts it when an FP
instruction reaches EX and the instruction waits there until `done`, exactly
as a divide does. One datapath serves both formats: a single is unpacked into
the top 24 bits of the 53-bit significand, and only the rounder (and the
divide/square-root iteration count) looks at the format.

| Module | Does | Algorithm | Cycles in EX |
|---|---|---|---:|
| `fp_misc` | sign injection, FMIN/FMAX, FEQ/FLT/FLE, FCLASS, FMV | combinational: sign and magnitude compare on the bit patterns | 1 |
| `fp_f2i` | FCVT.W, FCVT.WU | shift the binary point below bit 53, round the fraction, range check, saturate | 2 |
| `fp_fma` + `fp_round` | FADD, FSUB, FMUL, the four fused multiply-adds, FCVT.S.D, FCVT.D.S, FCVT.fmt.W/WU | one fused multiply-add datapath (below) | 5 |
| `fp_divsqrt` + `fp_round` | FDIV, FSQRT | radix-2 digit recurrence, two steps per cycle | 18 (single), 32 (double) |
| (in `fpu.sv`) | results that need no arithmetic: a NaN, an infinity, x/0, 0 x anything... | decided from the operand classes | 2 |

**The multiply-add datapath** is the classic one-shifter arrangement (the one
FPnew's `fpnew_fma` and the textbooks use). Everything is brought to the form
P x Q + R: FADD is a x 1 + b, FMUL is a x b + 0, a conversion is 0 x 1 + (the
value to round into the new format). The 106-bit product sits at a fixed place
in a 163-bit window and only the addend moves: at the top when it is the
larger, shifted right by the exponent difference otherwise, with whatever
falls off the bottom collected as a sticky bit. The five cycles are:

1. *Unpack.* Signs, exponents, significands, operand classes; the shift
   distance and the exponent of the window's top bit; special cases decided.
2. *Multiply and align.* Four 53 x 17-bit partial products (DSP blocks) are
   registered; in parallel the addend is shifted into place.
3. *Add.* Three levels of 3:2 carry-save adders reduce the four partial
   products and the addend to two numbers, and one carry-propagate addition
   finishes. For an effective subtraction the addend is inverted. The adder
   produces both `P - A - 1` and `P - A` (the same sum with carry-in 0 and 1,
   in carry-select halves); the right one is picked from the sticky bit, and
   if it is negative the magnitude is the bitwise complement of the first, so
   no second carry chain is needed to negate.
4. *Normalise.* The leading one is found and shifted to the top two bits of
   distance per level (shift by 0/64/128, then 0/16/32/48, 0/4/8/12, 0/1/2/3),
   so the zero tests of a level run side by side. The exponent follows.
5. *Round* (`fp_round`). If the exponent is below the format's minimum the
   significand is first shifted right into the subnormal range; then one
   incrementer rounds at 24 or 53 bits, and overflow, underflow and inexact
   are derived. Tininess after rounding needs the rounding decision on the
   significand *before* the subnormal shift as well; that is a second, tiny
   instance of the same rule (`fp_roundup`).

**Divide and square root** produce the result most significant bit first:
divide subtracts the divisor from the remainder and keeps the difference when
it is not negative; square root subtracts `4 * root + 1` after bringing down
two radicand bits. They share one subtractor chain, used twice per clock (two
result bits per cycle). 56 bits are produced for a double (53, a guard and a
round bit, and one more because a quotient can start with a zero), 28 for a
single; what remains in the remainder is the sticky bit. Subnormal operands
are normalised first, one bit position per cycle, which costs up to 52 extra
cycles in a case that is rare in practice.

### 12.4 One cycle or several? The timing estimate decided

The integer core's longest path is 7.8 ns in Yosys' logic-only estimate
(section 7.4). Three building blocks on their own, registers in and out
(`make sta-blocks`):

| Block | Logic-only delay |
|---|---:|
| 53 x 53-bit multiplier | 10.0 ns |
| 53 x 17-bit multiplier (one partial product) | 5.5 ns |
| 165-bit adder | 6.1 ns |

A double-precision multiply alone is longer than the whole existing clock
period, and an FMA is a multiply, an alignment shift, a 165-bit add, a
normalisation and a rounding in series. A single-cycle FPU would have
stretched the clock by several times for every instruction, integer ones
included. So the arithmetic is split into the steps above, each shorter than
7.8 ns, and the instruction simply stays in EX for five cycles.

The trade-off is throughput. This FPU is *multi-cycle*, not *pipelined*: a
second FP instruction cannot enter while one is in progress, so back-to-back
additions cost five cycles each. A pipelined FPU (several operations in
flight, as in FPnew's configurable pipeline or VexRiscv's FPU, which can
deliver one result per cycle) would be up to five times faster on dense FP
code, at the price of forwarding and flush logic for in-flight results. And
because addition shares the multiply-add datapath it takes the same five
cycles as a multiply; a dedicated adder would be shorter, with more area.
Against software floating point (about 90 to 180 cycles per operation,
section 12.6) both choices were judged acceptable.

Three details kept the FPU from lengthening the critical path. The subnormal
shift distance is worked out one register early (`fp_denorm`), so the rounder
does not start with a subtraction. The normaliser is radix-4 (it was radix-2
at first and was the longest path). And the EX result multiplexer selects the
multiplier's product last, so adding the FPU's integer results to that
multiplexer does not sit in front of the product.

### 12.5 Integration into the pipeline

* **Registers and forwarding.** `fp_regfile` has three read ports (rs1, rs2
  and rs3 for the fused multiply-adds). The x and f registers are separate
  files; the decoder says which one each field names. The f operands have the
  same two forwarding sources as the integer ones (MEM and WB) and the same
  load-use stall after FLW/FLD. Integer results of FP instructions (compares,
  FCVT.W, FMV.X.W, FCLASS) go down the integer result path and are forwarded
  like any ALU result, so `flt` followed by a branch costs no stall.
* **Waiting in EX.** The FPU latches its operands in its first cycle. EX
  holds until `done`; MEM and WB drain meanwhile. FENCE.I, the only thing
  that can flush EX, kills the operation.
* **Flags and precise state.** In this pipeline every exception is detected
  in EX and nothing behind EX can flush an instruction that has left it, so
  an instruction that leaves EX is certain to commit. `fflags` therefore
  accumulates when the instruction leaves EX. Wrong-path instructions never
  reach EX (a mispredicted branch redirects from EX while they are still in
  ID), so they can leave no flags behind. CSR instructions already run alone
  (section 4), which is what makes reads of `fflags` exact and lets `frm` and
  `mstatus.FS` be checked in EX without races.
* **FLD and FSD.** The data path, the D-cache and the bus are 32 bits wide
  per access, so an 8-byte access is **two word accesses in MEM**: the low
  word at the address, then the high word at address + 4 (the address
  register steps on, the two store words swap places, the first load word is
  kept). Only word alignment is required, so a double at an address 12 mod 16
  straddles two cache lines and each word hits or misses on its own; a miss
  on the second word just holds MEM longer. *Can something go wrong between
  the two words?* No: misalignment is the only memory exception this platform
  has (there are no bus errors and no interrupts) and it is detected in EX
  for both words at once, before the first is written. The alternative, a
  64-bit path through the cache, would have widened the load multiplexers and
  the store bypass for every access and still needed two beats for the
  straddling case.
* **Commit port.** Three more fields (f register write, flags raised, the
  second store word) so the lockstep check sees FP results and flags as they
  happen instead of only when a later instruction reads them.
* **`FPU = 0`.** The F/D decoder is its own module, instantiated only with
  `FPU = 1`, and every F/D pipeline register is inside a generate block. The
  RV32IM configuration runs the same programs in the same number of cycles as
  before (CoreMark: 3,101,884 cycles for 10 iterations either way) and
  synthesises to the same 3,759 flip-flops, block RAMs and DSP blocks.
  Individual blocks moved by a few LUTs against the 0.1.0 sources (the CSR
  file from 1,520 to 1,558, the decoder from 112 to 106: ABC's mapping
  depends on the order of the netlist); the total happens to come out at the
  same 9,305.

### 12.6 Verification and results

| What | Command | Result |
|---|---|---|
| Golden model's arithmetic against TestFloat | `make fp-model-test` | 64,478,064 vectors, 0 mismatches |
| RTL FPU against the same TestFloat vectors (result and flags) | `make fpu-unit` | 64,478,064 vectors, 0 mismatches |
| RTL FPU against the model, random operands biased to special values, all 25 operations | `make fpu-unit` | 2,000,000 operations, 0 mismatches |
| Official rv32uf (11) and rv32ud (10) tests, golden model alone | `make iss-test` | 21 / 21 pass (71 / 71 with the integer ones) |
| rv32ui + rv32um on all three cores, rv32uf + rv32ud on the FPU core, lockstep | `make system` | 171 / 171 pass |
| Random programs with F/D instructions, seeds 1-100, FPU core, lockstep | `make system` | 100 / 100 pass |
| Same, seeds 1-1000 | `make random-soak` | 1,000 / 1,000 pass |
| F/D mutants: 10 in the pipeline around the FPU, 10 inside it, 1 in the model | `make mutants` | 21 / 21 caught |

The fused multiply-add vectors drive all four FMA instructions in turn (the
other three by flipping operand signs). The random programs
(`tests/random/rvgen.py --fp`) draw operands from a pool of special values and
aim at the pipeline: FP dependency chains, FLW/FLD followed by a use,
compare-then-branch, conversions of freshly computed integers, doubles that
straddle cache lines or collide in one D-cache set, FP instructions in the
shadow of branches, `fflags`/`frm` accesses in between, reserved rounding
modes, illegal encodings, stretches with `mstatus.FS` off, and a started
divide replaced under FENCE.I.

One real bug was found this way and it is worth recording: the first RTL
raised *invalid* for `(-inf) x NaN + (-inf)`, because the "infinity minus
infinity" test did not exclude a NaN among the multiplicands. TestFloat's
vectors had not reached the unit yet; the random comparison against the model
found it in the first 200,000 operations.

Performance (`make fp-bench`, [fp-benchmarks.md](fp-benchmarks.md)). The same
source built for RV32IM with compiler-rt's soft-float routines and for
RV32IMFD; checksums of the results are identical between the two:

| Kernel | soft float | hardware FPU | speed-up | with fused multiply-add | speed-up |
|---|---:|---:|---:|---:|---:|
| n-body (8 bodies, 12 steps) | 3,789,153 | 126,950 | 29.8x | 106,694 | 35.5x |
| LU factorisation 20 x 20 | 1,502,339 | 87,627 | 17.1x | 69,357 | 21.7x |
| Horner polynomial | 1,263,836 | 54,159 | 23.3x | 32,044 | 39.4x |
| Mandelbrot | 4,865,792 | 212,639 | 22.9x | 188,030 | 25.9x |
| FIR filter (single precision) | 2,183,820 | 224,946 | 9.7x | 158,582 | 13.8x |
| all five | 13,624,530 | 723,846 | 18.8x | 572,029 | 23.8x |

(cycles on core B, memory latency 10). Per operation, measured as one
operation per array element minus a copy loop: add 175 -> 7.5 cycles,
multiply 93 -> 7.5, divide 179 -> 34.5, compare 31 -> 3.8. With the FPU the
CPI rises to about 2.9, because most instructions are now FP operations that
wait in EX; the cycle count is what matters.

Resources (`make synth`) and timing (`make sta`):

| | Core B | Core B with the FPU |
|---|---:|---:|
| LUTs | 9,305 (28.5 %) | 16,047 (49.2 %) |
| Flip-flops | 3,759 | 5,308 |
| Block RAM (36 Kb) | 6.5 | 6.5 |
| DSP48E1 | 4 | 16 |
| Longest path, logic only | 7.8 ns | 8.0 ns |

The FPU block is 5,597 LUTs, 1,093 flip-flops and 12 DSP blocks (multiply-add
datapath 2,139 LUTs, divide/square root 934, float-to-integer 523, rounder
464, one-cycle operations 445); the rest of the increase is the f register
file, three 64-bit forwarding multiplexers and the F/D pipeline registers.
The longest path with the FPU is still the integer one of section 7.4
(forwarding multiplexer, multiplier, result multiplexer); it is 0.2 ns longer
because the forwarding multiplexer maps to one more LUT level, and no path
inside the FPU is longer. As everywhere in this report these are logic-only
estimates without placement or routing, not timing sign-off, and the design
has not been run on a board.

### 12.7 Limitations of the FPU

* Multi-cycle, not pipelined (section 12.4): one FP operation at a time.
* FADD/FSUB take the same five cycles as a multiply.
* Radix-2 divide and square root, two bits per cycle; subnormal operands add
  up to 52 cycles.
* Core A has no FPU.
* No Zfh (half precision), Zfa or Q; RV32 only, so no FCVT.L or FMV.X.D.
* FLD/FSD need word alignment only; an address that is not a multiple of 4
  traps, and no handler here emulates misaligned FP accesses.
* NaN payloads are not propagated (RISC-V does not require it).
