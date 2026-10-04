# Changelog

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
