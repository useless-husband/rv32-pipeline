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
