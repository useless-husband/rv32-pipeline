"""Randomised instruction streams (tests/random/rvgen.py) on both cores in
lockstep with the golden model.  Seeds are fixed: 1..RANDOM_SEEDS (default
100).  A failure prints the seed and the command that reproduces it."""

import os
import subprocess
import sys

import pytest

from conftest import BUILD, CORES, REPO, assemble, run_vsim

SEEDS = range(1, int(os.environ.get("RANDOM_SEEDS", "100")) + 1)
LENGTH = int(os.environ.get("RANDOM_LENGTH", "3000"))


def build_program(seed):
    out = BUILD / "random"
    out.mkdir(parents=True, exist_ok=True)
    src, elf = out / f"seed{seed}_n{LENGTH}.S", out / f"seed{seed}_n{LENGTH}.elf"
    if not elf.exists():
        subprocess.run([sys.executable, str(REPO / "tests/random/rvgen.py"), "--seed", str(seed),
                        "--length", str(LENGTH), "-o", str(src)], check=True)
        assemble(src, elf)
    return elf


@pytest.mark.parametrize("core", CORES)
@pytest.mark.parametrize("seed", SEEDS)
def test_random_stream(core, seed):
    elf = build_program(seed)
    r = run_vsim(core, elf, "--max-cycles", "5000000")
    assert r.returncode == 0, (
        f"random seed {seed} failed on core {core} (exit {r.returncode}).\n"
        f"reproduce: make random-one SEED={seed} CORE={core}\n{r.stderr[-4000:]}")
