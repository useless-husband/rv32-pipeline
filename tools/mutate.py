#!/usr/bin/env python3
"""Mutation check: do the tests notice a broken design?

Each mutant is a one-line change to the RTL (or to the golden model).  For
every mutant the tool copies the sources into build/mutants/<id>/, applies
the change, rebuilds what the change touches and runs the test suites that
could notice it.  A mutant is "killed" when at least one suite fails.

    python3 tools/mutate.py            # all mutants, Markdown table on stdout
    python3 tools/mutate.py fwd_mem    # just one

Suites: unit = the module's cocotb test; rvtests = the 50 riscv-tests in
lockstep; random = random programs (seeds 1-30) in lockstep; iss = the
riscv-tests on the golden model alone.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORK = REPO / "build" / "mutants"
COPY = ["Makefile", "rtl", "sim", "model", "sw", "tests"]
SEEDS = range(1, 31)

# id, file, original text, replacement, what it breaks, unit test, cores
MUTANTS = [
    ("fwd_mem", "rtl/core_pipe.sv",
     "if (m_valid && m_rd_we && !m_is_load && m_rd == e_rs1) fwd1 = m_result;",
     "if (1'b0) fwd1 = m_result;",
     "no MEM->EX forwarding for rs1", None, ["pipe"]),
    ("fwd_wb", "rtl/core_pipe.sv",
     "else if (w_valid && w_rd_we && w_rd == e_rs2) fwd2 = w_result;",
     "else if (1'b0) fwd2 = w_result;",
     "no WB->EX forwarding for rs2", None, ["pipe"]),
    ("no_load_use", "rtl/core_pipe.sv",
     "assign load_use = e_valid && e_is_load && e_rd_we &&",
     "assign load_use = 1'b0 && e_valid && e_is_load && e_rd_we &&",
     "load-use hazard not detected (no stall)", None, ["pipe"]),
    ("no_id_flush", "rtl/core_pipe.sv",
     "if (rst || redirect_ex || redirect_mem) begin",
     "if (rst || redirect_mem) begin",
     "ID not flushed on a mispredict (wrong-path instruction executes)", None, ["pipe"]),
    ("no_operand_refresh", "rtl/core_pipe.sv",
     "e_rs1_val <= fwd1;\n            e_rs2_val <= fwd2;\n        end\n    end",
     "e_rs1_val <= e_rs1_val;\n            e_rs2_val <= fwd2;\n        end\n    end",
     "EX loses a forwarded rs1 while held by a D-cache miss", None, ["pipe"]),
    ("dirty_lost", "rtl/dcache.sv",
     "if (we && h0) dirty0[idx] <= 1'b1;",
     "if (we && h0) dirty0[idx] <= 1'b0;",
     "store hit in way 0 does not mark the line dirty (data lost on eviction)", "test_caches.py::test_dcache",
     ["pipe"]),
    ("no_store_bypass", "rtl/dcache.sv",
     "if (byp_v && byp_idx == idx && !byp_way) d0 =",
     "if (1'b0 && byp_idx == idx && !byp_way) d0 =",
     "load right after a store to the same line (way 0) reads stale data", "test_caches.py::test_dcache",
     ["pipe"]),
    ("lru_frozen", "rtl/dcache.sv",
     "lru[idx] <= !h1;",
     "lru[idx] <= lru[idx];",
     "LRU bit not updated on hits (performance bug only)", "test_caches.py::test_dcache", ["pipe"]),
    ("fencei_no_inval", "rtl/icache.sv",
     "valid <= '0;\n                    end else if",
     "valid <= valid;\n                    end else if",
     "FENCE.I does not invalidate the I-cache (stale code runs)", "test_caches.py::test_icache", ["pipe"]),
    ("bht_stuck", "rtl/bpred.sv",
     "if (upd_taken && bht[uh] != 2'b11) bht[uh] <= bht[uh] + 2'b01;",
     "if (upd_taken && bht[uh] != 2'b11) bht[uh] <= bht[uh];",
     "branch counters never move toward taken (performance bug only)", "test_bpred.py::test_bpred", ["pipe"]),
    ("sra_logical", "rtl/alu.sv",
     "`ALU_SRA:  y = $unsigned($signed(a) >>> sh);",
     "`ALU_SRA:  y = a >> sh;",
     "SRA/SRAI shift in zeros", "test_alu.py", ["single", "pipe"]),
    ("rem_sign", "rtl/divider.sv",
     "else if (is_rem) result = neg_r ? -r : r;",
     "else if (is_rem) result = r;",
     "REM result has the wrong sign for negative dividends", "test_muldiv.py::test_divider", ["pipe"]),
    ("branch_legal", "rtl/decoder.sv",
     "legal = (funct3 != 3'b010) && (funct3 != 3'b011);",
     "legal = 1'b1;",
     "reserved branch encodings accepted instead of trapping", "test_decoder.py", ["single", "pipe"]),
    ("mepc_unmasked", "rtl/csr_file.sv",
     "12'h341: mepc <= {wval[31:2], 2'b00};",
     "12'h341: mepc <= wval;",
     "mepc keeps the low two bits of a CSR write", "test_csr_file.py", ["single", "pipe"]),
    ("single_bltu", "rtl/core_single.sv",
     "3'b110: taken = (x1 < x2);",
     "3'b110: taken = ($signed(x1) < $signed(x2));",
     "single-cycle BLTU compares signed", None, ["single"]),
    ("model_mulhsu", "model/rv_iss.c",
     "case 2: return (uint32_t)(((int64_t)sa * (int64_t)(uint64_t)b) >> 32);",
     "case 2: return (uint32_t)(((int64_t)sa * (int64_t)sb) >> 32);",
     "golden model: MULHSU treats rs2 as signed", None, []),
]


def sh(cmd, cwd, timeout=900):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True, timeout=timeout)


def prepare(mid, path, old, new):
    d = WORK / mid
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    for item in COPY:
        src = REPO / item
        (shutil.copytree if src.is_dir() else shutil.copy)(src, d / item)
    (d / "build").mkdir()
    for sub in ("rvtests", "random", "third_party"):
        if (REPO / "build" / sub).exists():
            os.symlink(REPO / "build" / sub, d / "build" / sub)
    f = d / path
    text = f.read_text()
    assert text.count(old) == 1, f"{mid}: original text must occur exactly once in {path}"
    f.write_text(text.replace(old, new))
    return d


def run_suites(d, unit, cores, model):
    res = {}
    env = f'PYTHON="{sys.executable}"'
    if unit:
        r = sh(f'{env} "{sys.executable}" -m pytest -q -x "tests/unit/{unit}"', d)
        res["unit"] = r.returncode != 0
    if model:
        r = sh("make -s iss-test", d)
        res["iss"] = r.returncode != 0
    for core in cores:
        r = sh(f"make -s build/vsim_{core}", d)
        if r.returncode:
            res[f"build {core}"] = True
            continue
        fails = 0
        for elf in sorted((REPO / "build" / "rvtests").glob("*.elf")):
            p = sh(f'./build/vsim_{core} --quiet --max-cycles 2000000 "{elf}"', d, timeout=120)
            fails += p.returncode != 0
        res[f"rvtests {core}"] = fails
        fails = 0
        for seed in SEEDS:
            elf = REPO / "build" / "random" / f"seed{seed}_n3000.elf"
            p = sh(f'./build/vsim_{core} --quiet --max-cycles 5000000 "{elf}"', d, timeout=120)
            fails += p.returncode != 0
        res[f"random {core}"] = fails
    return res


def main():
    pick = set(sys.argv[1:])
    missing = [s for s in SEEDS if not (REPO / "build" / "random" / f"seed{s}_n3000.elf").exists()]
    if missing or not (REPO / "build" / "rvtests").exists():
        sys.exit("run 'make system' first (it builds the riscv-tests and the random programs)")
    rows = []
    for mid, path, old, new, what, unit, cores in MUTANTS:
        if pick and mid not in pick:
            continue
        d = prepare(mid, path, old, new)
        res = run_suites(d, unit, cores, model=path.startswith("model/"))
        killed = any(bool(v) for v in res.values())
        detail = ", ".join(f"{k}: {'FAIL' if v is True else (str(v) + ' failed') if v else 'pass'}"
                           for k, v in res.items())
        rows.append((mid, path, what, "killed" if killed else "SURVIVED", detail))
        print(f"{mid:20s} {'killed' if killed else 'SURVIVED':8s} {detail}", file=sys.stderr, flush=True)
        shutil.rmtree(d, ignore_errors=True)
    print("| Mutant | File | What it breaks | Result | Suites (failing runs) |")
    print("|---|---|---|---|---|")
    for mid, path, what, verdict, detail in rows:
        print(f"| `{mid}` | `{path}` | {what} | {verdict} | {detail} |")
    if any(r[3] != "killed" for r in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()
