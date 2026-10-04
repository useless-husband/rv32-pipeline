"""Performance assertions: a predictor or cache that is functionally
correct but no longer does its job passes every lockstep test, so the
pipelined core's CoreMark run must also stay within these bounds.  Measured
with clang 23 (10 iterations, whole run): CPI 1.19, 8.4 % of conditional
branches and 3.0 % of jumps mispredicted, I-cache misses 0.16 %, D-cache
misses 0.04 %; the limits leave room for small codegen changes.  Much older
clang releases generate different code (LLVM 18 emits ~1.7x as many jumps and
fails the jump bound), so CI pins LLVM 23."""

import json

from conftest import BUILD, run_vsim


def test_coremark_pipeline_efficiency(tmp_path):
    out = tmp_path / "cm.json"
    r = run_vsim("pipe", BUILD / "sw" / "coremark.elf", "--json", out)
    assert r.returncode == 0, r.stderr[-2000:]
    d = json.loads(out.read_text())
    assert d["cpi"] < 1.3, d
    assert d["branch_mispredicts"] < 0.15 * d["branches"], "conditional branch prediction degraded"
    assert d["jump_mispredicts"] < 0.10 * d["jumps"], "jump/return prediction degraded"
    assert d["dcache_misses"] < 0.01 * d["dcache_accesses"], "D-cache miss rate degraded"
    assert d["icache_misses"] < 0.01 * d["icache_accesses"], "I-cache miss rate degraded"
