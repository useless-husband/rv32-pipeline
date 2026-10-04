# Design notes

This file explains how the two cores, the golden model and the test
infrastructure fit together, the problems that took real thought, and the
alternatives that were considered and rejected. The measured results are in
[report.md](report.md); the beginner's walkthrough is [導讀.zh-TW.md](導讀.zh-TW.md).

## 1. Overview

```
             program.elf
                 |
     +-----------+-------------+
     |                         |
  $readmemh                 ELF loader
     v                         v
+------------+  commit   +-------------+
| core A or  |---------->|  lockstep   |<---- golden model (model/rv_iss.c)
| core B RTL |  port     |  compare    |      one rv_step() per commit
| (Verilator)|           +-------------+
+------------+                 |
     | I/O writes              v
     v                    first difference -> report, exit 2
  console / EXIT
```

Everything is driven from one C++ harness (`sim/sim_main.cpp`) compiled twice,
once around each core. The harness loads the ELF into the golden model, writes
a private `$readmemh` image for the RTL memory, resets the core and then, for
every clock cycle:

1. evaluates the falling edge and samples the commit port, the I/O port and
   the performance-event bits;
2. if the core committed an instruction, steps the model once and compares
   the two records field by field;
3. prints console bytes and watches for the EXIT register;
4. evaluates the rising edge.

## 2. ISA: what is and is not implemented

Implemented, identically in both cores and in the golden model:

* **RV32I** (all 37 computational, load/store and control-transfer
  instructions, FENCE as a no-op), **M** (MUL, MULH, MULHSU, MULHU, DIV, DIVU,
  REM, REMU with the ISA's division-by-zero and overflow results),
  **Zicsr** (the six CSR instructions), **Zifencei** (FENCE.I).
* **Machine mode only.** ECALL, EBREAK, MRET; WFI executes as a no-op.
* **Exceptions** (synchronous only), all precise:

  | Cause | mcause | mtval |
  |---|---|---|
  | jump or taken branch to an address that is not 4-byte aligned | 0 | target |
  | illegal instruction (bad encoding, unknown CSR, write to a read-only CSR) | 2 | instruction |
  | EBREAK | 3 | 0 |
  | misaligned load | 4 | address |
  | misaligned store | 6 | address |
  | ECALL | 11 | 0 |

  The exception is reported on the faulting instruction, nothing it would
  have written is written, `mepc` gets its pc, `mstatus.MPIE` gets `MIE` and
  `MIE` is cleared, and fetch continues at `mtvec`.
* **CSRs**: `mstatus` (MIE, MPIE writable; MPP reads as M), `misa` (reads
  RV32IM, writes ignored), `mie`/`mip` (read zero: no interrupt sources),
  `mtvec` (direct mode; the low two bits read as zero), `mscratch`, `mepc`
  (low two bits zero), `mcause`, `mtval`, `mvendorid`/`marchid`/`mimpid`/
  `mhartid`/`mconfigptr` (zero), 64-bit `mcycle`, `minstret` and
  `mhpmcounter3`-`mhpmcounter12` with their `...h` halves, and the read-only
  user aliases `cycle`, `instret`, `hpmcounter3`-`12`. A write to `minstret`
  replaces that instruction's own increment, as the ISA requires.
* **Event counters** are hard-wired (there are no `mhpmevent` selectors):

  | Counter | Event | Counter | Event |
  |---|---|---|---|
  | mhpmcounter3 | I-cache misses | mhpmcounter8 | conditional branch mispredictions |
  | mhpmcounter4 | D-cache accesses | mhpmcounter9 | JAL/JALR executed |
  | mhpmcounter5 | D-cache misses | mhpmcounter10 | JAL/JALR mispredictions |
  | mhpmcounter6 | D-cache write-backs | mhpmcounter11 | load-use bubbles |
  | mhpmcounter7 | conditional branches executed | mhpmcounter12 | instructions delivered by fetch |

  Core A has no caches or predictor; its cache and misprediction counters
  stay zero.

Not implemented: compressed instructions (C), atomics (A), floating point,
interrupts (timer, software, external), user and supervisor modes, virtual
memory, PMP, the `time` CSR, `mcountinhibit`, `mhpmevent*`, hardware support
for misaligned accesses (they trap; the riscv-tests environment emulates them
in its trap handler, like OpenSBI does on real hardware), debug mode.

**Platform.** 1 MiB of RAM at `0x8000_0000` (reset PC `0x8000_0000`); every
address with bit 31 set is cacheable RAM, everything below is uncached I/O.
Two I/O registers: `0x1000_0000` (store: one byte to the console) and
`0x1000_0004` (store: stop the simulation; HTIF convention, `1` = pass,
`(n << 1) | 1` = exit code `n`). I/O reads return zero.

## 3. The golden model and the commit port

`model/rv_iss.c` is about 450 lines of C written from the ISA manual. One
`rv_step()` executes one instruction (or takes one exception) and fills an
`rv_commit` record:

```
pc, instruction, trap?, mcause, rd written?, rd, value,
memory written?, word address, data (in byte lanes), byte mask
```

Both cores produce the same record on their commit port when an instruction
leaves the machine: core A every cycle, core B from its WB stage. The harness
compares all fields; for a store, only the written byte lanes count (the
cores replicate SB/SH data across lanes, the model does not).

**Values that depend on timing.** A read of `mcycle`, `cycle` or an event
counter legitimately differs between a core and the model. The model flags
such reads (`nondet`) and adopts the core's value, so the program continues
with the same register contents on both sides. `minstret` is not on that list:
it must match exactly, which is why core B runs CSR instructions alone (5.4).

**Why our own model instead of Spike.** The point of the project is to
implement the ISA, and a second independent implementation is what lockstep
needs. The risk is a common-mode error (the same misunderstanding in model and
RTL); the official riscv-tests run on the model alone guard against it, and a
mutation of the model (MULHSU sign handling) is caught by them.

## 4. Core A: single cycle

`rtl/core_single.sv`: the textbook datapath (diagram: [single_cycle.svg](single_cycle.svg)).
The PC addresses a combinational instruction memory; the decoder, register
file, ALU, branch comparator and a combinational multiplier/divider work in the
same cycle; the load/store aligner talks to a combinational data memory; the
write-back multiplexer writes the register file at the clock edge. Next PC is
`pc+4`, the branch/JAL target, the JALR target, `mtvec` on a trap or `mepc`
on MRET. CPI is exactly 1 by construction; the cost is the clock period
(report.md 7.4).

## 5. Core B: the pipeline

`rtl/core_pipe.sv` (diagram: [pipeline.svg](pipeline.svg)).

### 5.1 Stall and flush rules

Every stage has a valid bit. The whole control is a handful of equations:

| Signal | Meaning |
|---|---|
| `m_stall` | MEM's instruction cannot finish: D-cache not ready, or FENCE.I still flushing caches |
| `e_hold = m_stall or divider busy` | EX keeps its instruction |
| `d_hold = e_hold or load-use or CSR waiting` | ID keeps its instruction |
| IF advances when the I-cache hits and ID is not held | otherwise ID receives a bubble |
| `redirect_ex` | EX fires and its real next PC differs from the predicted one: flush IF and ID |
| `redirect_mem` | FENCE.I completes in MEM: flush IF, ID and EX, refetch pc+4 |

A stage that is held keeps its contents; the stage after it receives a bubble.
Side effects that happen in EX (CSR writes, trap entry, MRET, predictor
updates, starting the divider) are gated by "EX fires", so a held or squashed
instruction never performs them twice or at all.

### 5.2 Forwarding and the load-use stall

EX takes each source operand from, in priority order: the instruction in MEM
(its ALU/CSR/link/multiply result), the instruction in WB (its final value),
or the value read in ID. A load's data exists only at the end of MEM, so an
instruction that needs it in the very next cycle waits one cycle in ID
(`load_use`); after that the value arrives through the WB path. The register
file writes in WB and bypasses that value to a same-cycle read in ID, which
closes the last gap.

### 5.3 Holding EX without losing operands

A subtle hazard that is easy to miss in a textbook-style design: when EX is
held by a D-cache miss in MEM, WB empties after one cycle. An
instruction in EX that got an operand by forwarding from WB would lose it.
The fix: while EX is held, its operand registers are rewritten every cycle
with the forwarded values, so whatever was forwarded once stays. (The mutant
`no_operand_refresh` removes this line; one riscv-test and all 30 random
programs catch it.)

### 5.4 CSR instructions run alone

A CSR instruction waits in ID until EX, MEM and WB are empty, then executes in
EX. This costs three cycles per CSR access, which are rare, and buys two
things: a read of `minstret` sees every older instruction retired (the model
agrees exactly), and a write to `mtvec`/`mepc` is visible to everything after
it without extra forwarding paths.

### 5.5 Exceptions and MRET

All exceptions are detected in EX: illegal and system instructions come from
the decoder, misaligned addresses and jump targets from EX's own adders, and
nothing after EX can fault. The trap updates the CSRs when EX fires and
redirects fetch to `mtvec`; the instruction continues down the pipe as a
"trap" record so the commit port reports it, without writing anything. MRET
redirects to `mepc`. Because the redirect logic simply compares the real next
PC with the predicted one, traps and MRET need no special flush path.

### 5.6 FENCE.I

Self-modifying code writes instructions through the D-cache, which is
write-back, so the bytes may sit in a dirty line that the I-cache cannot see.
FENCE.I therefore waits in MEM while (1) the D-cache writes back every dirty
line, (2) the I-cache clears its valid bits (after any refill in progress
finishes), and only then (3) fires and redirects fetch to its pc+4, flushing
IF, ID and EX. Any refill after step 1 reads up-to-date memory, and anything
fetched before step 2 is thrown away.

### 5.7 Divider and multiplier

The multiplier is one 33x33 signed product in EX (Yosys maps it to four
DSP48E1); it is also the longest path in core B (report.md 7.4). The divider computes one
quotient bit per cycle on magnitudes and fixes the signs at the end; it latches
its operands when it starts, so forwarding sources moving on do not matter.

## 6. Caches and memory bus

### 6.1 Organisation

| | I-cache | D-cache |
|---|---|---|
| capacity | 4 KiB (parameter) | 4 KiB (parameter) |
| organisation | direct mapped | 2-way set associative, 1 LRU bit per set |
| line | 16 bytes | 16 bytes |
| write policy | read only | write-back, write-allocate |
| arrays | tag + data in block RAM, valid bits in flip-flops | same, plus dirty bits |
| I/O | n/a | addresses with bit 31 clear bypass the cache |

### 6.2 Synchronous-read arrays

Block RAM on the FPGA registers its read address, so the data appears one
cycle after the address. Both caches therefore receive the address of the
access that will be in their stage in the next cycle (`addr_next`: the next
PC for the I-cache; EX's computed address, or MEM's own address while MEM is
stalled, for the D-cache). In the following cycle the tag and line are already
at the array outputs and the hit check is just a comparison. The pipeline
guarantees the invariant "what was presented as `addr_next` is what is now in
the stage", and the unit tests drive the caches exactly that way.

### 6.3 Miss handling

D-cache miss: choose a victim (an invalid way, else the LRU way); if it is
dirty, send its line to memory; read the missing line; write it into the
arrays; spend one cycle re-reading them; the access then hits normally. A
store miss becomes a store hit after the refill (write-allocate). I-cache
miss: read the line, write it, re-read, hit. Because a refill cannot be
cancelled once the bus request is out, a redirect during an I-cache refill just
lets it finish; a miss detected in the very cycle of a redirect starts no
refill at all (the `kill` input), which saves a full memory latency on most
mispredictions that would otherwise fetch from a cold line.

### 6.4 The store bypass

A store hit writes the data array at the end of its MEM cycle. The access
behind it (now in EX) presented its address at that same clock edge, and a
block RAM in read-first mode returns the old bytes. The D-cache keeps the last
store (set, way, data, byte mask) for one cycle and merges it into the next
read when the set matches. Without it, a load right after a store to the same
line reads stale data (mutant `no_store_bypass`, caught by the unit test, five
riscv-tests and all random programs).

### 6.5 Bus and memory model

One line-wide bus (32-bit address, 128-bit data, 16-bit byte strobe): a master
holds `req` until a one-cycle `ack`. Uncached accesses are strobed line
writes or line reads from which the word is picked. The arbiter grants the
D-cache first when both ask in the same cycle and keeps a grant until the ack.
The simulation memory (`rtl/sim/mem_model.sv`) acknowledges `LATENCY` cycles
after accepting a request (default 10) and moves the whole line in that beat.

## 7. Branch prediction

* **BTB**, 128 entries, direct mapped, full tags: target and kind (branch,
  jump, return) for every taken branch and every jump.
* **BHT**, 256 two-bit saturating counters indexed by PC, starting weakly
  not-taken. A conditional branch in the BTB is predicted taken when its
  counter is 2 or 3.
* **Return-address stack**, 8 entries: JAL/JALR writing `ra` or `t0` push
  pc+4, a JALR through `ra`/`t0` that is not a call pops (the ISA's hint
  convention). A return found in the BTB is predicted from the top of the
  stack.
* All three are updated when the instruction resolves in EX, never
  speculatively, so wrong-path instructions cannot corrupt them; the price is
  that a return fetched before the matching call reached EX uses a stale stack
  top.

During development the BTB had 32 entries; measuring it showed that capacity,
not the counters, was the problem: over the whole Dhrystone program only 46 %
of jumps were predicted, and 128 entries raised that to 95 % (and conditional
branches from 92.0 % to 94.9 %). The numbers are in report.md 7.3.

## 8. Hard problems, in short

| Problem | Resolution |
|---|---|
| Block RAM reads one cycle late | present `addr_next`; hit check in the following cycle (6.2) |
| Read-during-write on a store hit | one-entry store bypass (6.4) |
| Forwarded operands vanish while EX waits | rewrite EX operands while held (5.3) |
| Self-modifying code with a write-back D-cache | FENCE.I: write back, invalidate, then refetch, in that order (5.6) |
| `minstret` must match the model exactly | CSR instructions run alone (5.4) |
| Timing-dependent counter reads in lockstep | model adopts the core's value for those reads only (3) |
| `ma_data` needs misaligned accesses | trap-and-emulate handler in the test environment |
| Ubuntu's Verilator 5.020, Icarus 12, Yosys 0.33 | no packages, structs, interfaces or casts to parameter widths |
| Checkout path with spaces and CJK characters | relative paths only; Verilator output compiled without its makefiles |

## 9. Alternatives considered and rejected

* **Asynchronous-read caches** (distributed RAM): simpler control, but 8 KiB
  of LUT RAM and an unrealistic memory for an FPGA design.
* **Resolving branches in ID**: a 1-cycle penalty instead of 2, but it needs
  forwarding into ID and a comparator in front of the register file, and the
  predictor already removes most penalties.
* **Write-through D-cache**: no dirty state and a trivial FENCE.I, but every
  store would hit the bus; with a 10-cycle memory that needs a write buffer,
  which is more logic than write-back.
* **Speculative return-address stack** with repair on misprediction: better
  accuracy on back-to-back returns, considerably more state to restore.
* **A two-stage multiplier**: would shorten core B's longest path (7.7-8.0 ns
  logic-only) at the cost of one more hazard case. Listed as future work.
* **Formal verification with riscv-formal**: stronger guarantees than
  simulation, but a separate project; the commit port was designed so an RVFI
  wrapper could be added.
