# Changelog

## 0.2.0 - 2026-10-06

Floating point: the F and D extensions on the pipelined core.

### Added
- Golden model: RV32F and RV32D (`has_fpu`, `rvsim --fpu`) with its own
  integer-only IEEE 754 arithmetic (`model/rv_fp.c`), checked against
  Berkeley TestFloat (`make fp-model-test`, 64,478,064 vectors).
- FPU (`rtl/fpu.sv` and `rtl/fp_*.sv`): fused multiply-add datapath for
  add/sub/mul/FMA and conversions to floating point, iterative divide and
  square root (two bits per cycle), float-to-integer, one-cycle operations,
  shared rounder; all five rounding modes, exact flags.
- Core B parameter `FPU` (default 0 = the RV32IM core): 32 f registers with
  forwarding and load-use stall, `fflags`/`frm`/`fcsr`, `mstatus.FS`, FLD/FSD
  as two word accesses, F/D fields on the commit port.
- Tests: Verilator testbench of the FPU against TestFloat and against the
  model (`make fpu-unit`), official rv32uf/rv32ud, random programs with F/D
  instructions (`rvgen.py --fp`), 21 F/D mutants.
- `fpbench` (n-body, LU, Horner, Mandelbrot, FIR) built for soft float and
  for the FPU (`make fp-bench`), `fpdemo` (`make fpdemo`).
- Synthesis and logic-only timing of core B with the FPU; `make sta-blocks`.
- Report chapter 12, design notes section 10, beginner's guide section 6.

### Changed
- `make test` also runs the TestFloat checks; `make system`, `make
  random-soak` and `make mutants` cover a third build (core B with the FPU).
- The EX result multiplexer selects the multiplier's product last.

### Fixed
- `make mutants`: the `bht_stuck` mutant no longer matched the predictor
  source after the counter table was packed into a flat vector.

## 0.1.0 - 2026-10-04

First complete version.

### Added
- Golden model: RV32IM + Zicsr + Zifencei instruction-set simulator in C with
  commit records, disassembler and a standalone simulator (`build/rvsim`).
- Core A: single-cycle RV32IM core with machine-mode CSRs and exceptions.
- Core B: five-stage pipeline with MEM/WB forwarding, load-use stall, branch
  resolution in EX, BTB + 2-bit counters + return-address stack, iterative
  divider, 4 KiB I-cache, 4 KiB 2-way write-back D-cache, arbiter and a
  latency-configurable memory model.
- Verilator harness with lockstep comparison against the golden model,
  statistics and a pipeline-occupancy recorder.
- Tests: official riscv-tests (rv32ui, rv32um) with our own environment,
  random hazard-stressing programs, cocotb unit tests, CoreMark efficiency
  bounds, mutation checks.
- Bare-metal runtime, demo program, CoreMark and Dhrystone ports.
- Pipeline viewer (`make pipeview`), benchmark driver (`make bench`), Yosys
  synthesis for the XC7S50 (`make synth`) and a logic-only timing estimate
  (`make sta`).
- Double-click launcher `跑跑看.command`, CI on GitHub Actions.
