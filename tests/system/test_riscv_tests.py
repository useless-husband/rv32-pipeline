"""The official riscv-tests (rv32ui, rv32um) on both cores, each run in
lockstep with the golden model.  A test passes when it reports success
through the EXIT register AND every committed instruction matched."""

import re

import pytest

from conftest import BUILD, CORES, REPO, run_vsim

RISCV_TESTS = BUILD / "third_party" / "riscv-tests"


def makefile_list(var):
    text = (REPO / "Makefile").read_text()
    m = re.search(rf"^{var} := ((?:.*\\\n)*.*)$", text, re.M)
    return m.group(1).replace("\\\n", " ").split()


TESTS = [f"rv32ui-{t}" for t in makefile_list("RV32UI")] + [f"rv32um-{t}" for t in makefile_list("RV32UM")]


def upstream_list(ext):
    frag = (RISCV_TESTS / "isa" / ext / "Makefrag").read_text()
    m = re.search(rf"^{ext}_sc_tests = \\\n((?:.*\\\n)*)", frag, re.M)
    return m.group(1).replace("\\\n", " ").split()


@pytest.mark.parametrize("ext", ["rv32ui", "rv32um"])
def test_list_matches_upstream(ext):
    """Our Makefile runs exactly the tests the pinned commit lists."""
    if not RISCV_TESTS.exists():
        pytest.skip("riscv-tests not fetched")
    ours = [t.split("-", 1)[1] for t in TESTS if t.startswith(ext)]
    assert ours == upstream_list(ext)


@pytest.mark.parametrize("core", CORES)
@pytest.mark.parametrize("test", TESTS)
def test_riscv_test(core, test):
    elf = BUILD / "rvtests" / f"{test}.elf"
    r = run_vsim(core, elf, "--max-cycles", "2000000")
    assert r.returncode == 0, f"{test} on {core}: exit {r.returncode}\n{r.stderr[-3000:]}"
