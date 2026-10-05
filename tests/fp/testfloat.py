#!/usr/bin/env python3
"""Run Berkeley TestFloat vectors through a checker.

    testfloat.py --gen build/third_party/berkeley-testfloat-3/.../testfloat_gen \
                 --check build/fp_check          # the golden model's arithmetic
    testfloat.py --gen ... --check build/fpu_tb  # the RTL FPU (Verilator)

For every operation, format and rounding mode `testfloat_gen` writes its test
vectors (operands, expected result, expected flags) and the checker reads
them on stdin and reports how many it checked and how many differed.
Two- and three-operand functions use TestFloat level 1; one-operand
functions use level 2, whose level 1 has only a few hundred cases.
The vector sequences are deterministic (TestFloat's own generator, default
seed), so the totals printed at the end are reproducible.

--only substr restricts the functions; -j runs that many pipelines at once;
--verbose prints every run (the RTL testbench also reports cycle counts).
"""

import argparse
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

MODES = ["near_even", "minMag", "min", "max", "near_maxMag"]
BINARY = ["add", "sub", "mul", "div"]
COMPARE = ["eq", "lt", "le"]          # FEQ is quiet, FLT/FLE signal on any NaN


def jobs():
    out = []
    for fmt in ("f32", "f64"):
        for op in BINARY:
            out += [(f"{fmt}_{op}", m, 1) for m in MODES]
        out += [(f"{fmt}_{op}", "near_even", 1) for op in COMPARE]
        out += [(f"{fmt}_mulAdd", m, 1) for m in MODES]
        for op in ("sqrt", "to_i32", "to_ui32"):
            out += [(f"{fmt}_{op}", m, 2) for m in MODES]
        for src in ("i32", "ui32"):
            out += [(f"{src}_to_{fmt}", m, 2) for m in MODES]
    out += [("f32_to_f64", m, 2) for m in MODES] + [("f64_to_f32", m, 2) for m in MODES]
    return out


def run(gen, check, fn, mode, level):
    g = [gen, f"-r{mode}", "-tininessafter", "-exact", "-level", str(level)]
    p1 = subprocess.Popen(g + [fn], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.run([check, fn, mode], stdin=p1.stdout, capture_output=True, text=True)
    p1.stdout.close()
    p1.wait()
    m = re.search(r"(\d+) vectors, (\d+) mismatches", p2.stdout)
    if not m or p2.returncode not in (0, 1):
        return fn, mode, 0, -1, (p2.stdout + p2.stderr).strip()
    return fn, mode, int(m.group(1)), int(m.group(2)), (p2.stdout + p2.stderr).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen", required=True)
    ap.add_argument("--check", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    todo = [j for j in jobs() if a.only in j[0]]
    total = bad = 0
    per_fn = {}
    failed = []
    with ThreadPoolExecutor(max_workers=a.j) as ex:
        for fn, mode, n, mism, text in ex.map(lambda j: run(a.gen, a.check, *j), todo):
            if a.verbose or mism:
                print(text, flush=True)
            if mism:
                failed.append(f"{fn} {mode}")
            total += n
            bad += max(mism, 0)
            c = per_fn.setdefault(fn, [0, 0])
            c[0] += 1
            c[1] += n
    print("| Function | Rounding modes | Vectors |")
    print("|---|---:|---:|")
    for fn, (modes, n) in per_fn.items():
        print(f"| `{fn}` | {modes} | {n:,} |")
    print(f"\ntotal: {total:,} vectors, {bad} mismatches" + (f", failed: {', '.join(failed)}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
