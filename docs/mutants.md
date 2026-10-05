| Mutant | File | What it breaks | Result | Suites (failing runs) |
|---|---|---|---|---|
| `fwd_mem` | `rtl/core_pipe.sv` | no MEM->EX forwarding for rs1 | killed | rvtests pipe: 50 failed, random pipe: 30 failed, perf pipe: FAIL |
| `fwd_wb` | `rtl/core_pipe.sv` | no WB->EX forwarding for rs2 | killed | rvtests pipe: 10 failed, random pipe: 30 failed, perf pipe: FAIL |
| `no_load_use` | `rtl/core_pipe.sv` | load-use hazard not detected (no stall) | killed | rvtests pipe: 6 failed, random pipe: 30 failed, perf pipe: FAIL |
| `no_id_flush` | `rtl/core_pipe.sv` | ID not flushed on a mispredict (wrong-path instruction executes) | killed | rvtests pipe: 1 failed, random pipe: 30 failed, perf pipe: FAIL |
| `no_operand_refresh` | `rtl/core_pipe.sv` | EX loses a forwarded rs1 while held by a D-cache miss | killed | rvtests pipe: 1 failed, random pipe: 30 failed, perf pipe: FAIL |
| `dirty_lost` | `rtl/dcache.sv` | store hit in way 0 does not mark the line dirty (data lost on eviction) | killed | unit: FAIL, rvtests pipe: 1 failed, random pipe: 30 failed, perf pipe: FAIL |
| `no_store_bypass` | `rtl/dcache.sv` | load right after a store to the same line (way 0) reads stale data | killed | unit: FAIL, rvtests pipe: 5 failed, random pipe: 30 failed, perf pipe: pass |
| `lru_frozen` | `rtl/dcache.sv` | LRU bit not updated on hits (performance bug only) | killed | unit: FAIL, rvtests pipe: pass, random pipe: pass, perf pipe: pass |
| `fencei_no_inval` | `rtl/icache.sv` | FENCE.I does not invalidate the I-cache (stale code runs) | killed | unit: FAIL, rvtests pipe: pass, random pipe: 30 failed, perf pipe: pass |
| `bht_stuck` | `rtl/bpred.sv` | branch counters never move toward taken (performance bug only) | killed | unit: FAIL, rvtests pipe: pass, random pipe: pass, perf pipe: FAIL |
| `sra_logical` | `rtl/alu.sv` | SRA/SRAI shift in zeros | killed | unit: FAIL, rvtests single: 4 failed, random single: 30 failed, rvtests pipe: 4 failed, random pipe: 30 failed, perf pipe: FAIL |
| `rem_sign` | `rtl/divider.sv` | REM result has the wrong sign for negative dividends | killed | unit: FAIL, rvtests pipe: 1 failed, random pipe: 29 failed, perf pipe: pass |
| `branch_legal` | `rtl/decoder.sv` | reserved branch encodings accepted instead of trapping | killed | unit: FAIL, rvtests single: pass, random single: 29 failed, rvtests pipe: pass, random pipe: 29 failed, perf pipe: pass |
| `mepc_unmasked` | `rtl/csr_file.sv` | mepc keeps the low two bits of a CSR write | killed | unit: FAIL, rvtests single: pass, random single: 14 failed, rvtests pipe: pass, random pipe: 14 failed, perf pipe: pass |
| `single_bltu` | `rtl/core_single.sv` | single-cycle BLTU compares signed | killed | rvtests single: 1 failed, random single: 30 failed |
| `model_mulhsu` | `model/rv_iss.c` | golden model: MULHSU treats rs2 as signed | killed | iss: FAIL |
| `ffwd_mem` | `rtl/core_pipe.sv` | no MEM->EX forwarding for f register rs1 | killed | rvtests pipe_fd: 9 failed, random pipe_fd: pass, random-fp pipe_fd: 30 failed |
| `ffwd_wb_rs3` | `rtl/core_pipe.sv` | no WB->EX forwarding for the fused multiply-add's third operand | killed | rvtests pipe_fd: 1 failed, random pipe_fd: pass, random-fp pipe_fd: 30 failed |
| `no_fload_use` | `rtl/core_pipe.sv` | FLW/FLD followed by a use of that f register: no stall | killed | rvtests pipe_fd: 8 failed, random pipe_fd: pass, random-fp pipe_fd: 30 failed |
| `fsd_same_word` | `rtl/core_pipe.sv` | the second word of FLD/FSD goes to the first word's address | killed | rvtests pipe_fd: 10 failed, random pipe_fd: pass, random-fp pipe_fd: 30 failed |
| `fld_one_beat` | `rtl/core_pipe.sv` | FLD/FSD access only one word | killed | rvtests pipe_fd: 10 failed, random pipe_fd: pass, random-fp pipe_fd: 30 failed |
| `frm_ignored` | `rtl/core_pipe.sv` | dynamic rounding mode does not read frm | killed | rvtests pipe_fd: pass, random pipe_fd: pass, random-fp pipe_fd: 29 failed |
| `fpu_no_kill` | `rtl/core_pipe.sv` | an FPU operation flushed by FENCE.I keeps running (its result goes to the next instruction) | killed | rvtests pipe_fd: pass, random pipe_fd: pass, random-fp pipe_fd: 26 failed |
| `fs_not_dirty` | `rtl/csr_file.sv` | mstatus.FS not set to dirty by a write to an f register | killed | rvtests pipe_fd: pass, random pipe_fd: pass, random-fp pipe_fd: 26 failed |
| `fflags_not_sticky` | `rtl/csr_file.sv` | fflags overwritten instead of accumulated | killed | rvtests pipe_fd: 4 failed, random pipe_fd: pass, random-fp pipe_fd: 30 failed |
| `fsqrt_rs2` | `rtl/fp_decoder.sv` | FSQRT with a nonzero rs2 field accepted instead of trapping | killed | rvtests pipe_fd: pass, random pipe_fd: pass, random-fp pipe_fd: 14 failed |
| `rmm_as_rne` | `rtl/fp_roundup.sv` | round-to-nearest-max-magnitude breaks ties to even | killed | fpu: FAIL |
| `align_sticky` | `rtl/fp_fma.sv` | addend bits shifted out of the adder window are forgotten | killed | fpu: FAIL |
| `fma_negative` | `rtl/fp_fma.sv` | a negative difference is not turned back into a magnitude | killed | fpu: FAIL |
| `tiny_before` | `rtl/fp_round.sv` | tininess detected before rounding (the RISC-V rule is after) | killed | fpu: FAIL |
| `nan_unboxed` | `rtl/fp_unpack.sv` | a single that is not NaN-boxed is used as it is | killed | fpu: FAIL |
| `f2i_limit` | `rtl/fp_f2i.sv` | FCVT.W accepts +2^31 | killed | fpu: FAIL |
| `fmin_zero` | `rtl/fp_misc.sv` | FMIN/FMAX do not order -0 below +0 | killed | fpu: FAIL |
| `sqrt_odd_exp` | `rtl/fp_divsqrt.sv` | square root ignores an odd exponent | killed | fpu: FAIL |
| `div_sticky` | `rtl/fp_divsqrt.sv` | divide/sqrt drop the remainder (inexact results look exact) | killed | fpu: FAIL |
| `inf_times_zero` | `rtl/fpu.sv` | infinity times zero is not an invalid operation | killed | fpu: FAIL |
| `model_rne` | `model/rv_fp.c` | golden model: round-to-nearest-even breaks ties away from zero | killed | iss: pass, testfloat: FAIL |
