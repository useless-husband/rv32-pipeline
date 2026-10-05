"""C programs that use the FPU, on core B with the FPU in lockstep with the
golden model: the floating-point demonstration (sw/demo/fpdemo.c), whose
output is fully determined by IEEE 754."""

import subprocess

from conftest import BUILD, FP_CORE, REPO, vsim

EXPECT = [
    "0.1 + 0.2 = 0x3fd3333333333334 = 0.30000000000000004440",
    "0.3       = 0x3fd3333333333333 = 0.29999999999999998889",
    "equal? no",
    "down         +1/3 = 0x3fd5555555555555  -1/3 = 0xbfd5555555555556",
    "up           +1/3 = 0x3fd5555555555556  -1/3 = 0xbfd5555555555555",
    "1/0       = 0x7ff0000000000000 (infinity)\n   flags: divide-by-zero",
    "sqrt(-1)  = 0x7ff8000000000000 (NaN)\n   flags: invalid",
    "1e308*10  = 0x7ff0000000000000 (infinity)\n   flags: overflow inexact",
    "(subnormal)\n   flags: underflow inexact",
    "sqrt(2)   = 0x3ff6a09e667f3bcd = 1.41421356237309514547",
]


def test_fpdemo():
    r = subprocess.run([str(vsim(FP_CORE)), "--max-cycles", "5000000", str(BUILD / "sw" / "fpdemo.elf")],
                       capture_output=True, text=True, timeout=600, cwd=REPO)
    assert r.returncode == 0, r.stderr[-3000:]
    for line in EXPECT:
        assert line in r.stdout, f"missing in the output: {line}\n{r.stdout}"
