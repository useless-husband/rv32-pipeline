"""M extension: the single-cycle core's combinational unit and the
pipelined core's iterative divider, against the Python reference on edge
cases (division by zero, INT_MIN / -1, signs) and random operands.  The
divider's latency is checked too: 34 cycles, or 2 for division by zero."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from rvref import EDGE, muldiv
from simrun import run


def operands(seed, n):
    rng = random.Random(seed)
    return [(a, b) for a in EDGE for b in EDGE] + \
           [(rng.getrandbits(32), rng.getrandbits(rng.choice([4, 16, 32]))) for _ in range(n)]


@cocotb.test()
async def comb_unit(dut):
    for f3 in range(8):
        for a, b in operands(3, 200):
            dut.op.value, dut.a.value, dut.b.value = f3, a, b
            await Timer(1, unit="ns")
            assert int(dut.y.value) == muldiv(f3, a, b), f"f3={f3} {a:#x} {b:#x}"


@cocotb.test()
async def iterative_divider(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value, dut.start.value, dut.kill.value, dut.ack.value = 1, 0, 0, 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    for f3 in range(4, 8):
        for a, b in operands(4, 60):
            dut.op.value, dut.a.value, dut.b.value, dut.start.value = f3 & 3, a, b, 1
            cycles = 0
            while True:
                await RisingEdge(dut.clk)
                await FallingEdge(dut.clk)
                dut.start.value = 0
                cycles += 1
                if int(dut.done.value):
                    break
                assert cycles < 40, "divider never finished"
            assert cycles == (1 if b == 0 else 33), f"latency {cycles} for b={b:#x}"
            assert int(dut.result.value) == muldiv(f3, a, b), f"f3={f3} {a:#x} {b:#x}"
            dut.ack.value = 1
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            dut.ack.value = 0
    # kill in the middle of a division returns to idle
    dut.op.value, dut.a.value, dut.b.value, dut.start.value = 0, 100, 7, 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.start.value, dut.kill.value = 0, 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.kill.value = 0
    for _ in range(40):
        await RisingEdge(dut.clk)
        assert not int(dut.done.value), "killed division still completed"


def test_muldiv_comb():
    run("muldiv_comb", ["muldiv_comb.sv"], "test_muldiv", name="muldiv_comb", testcase="comb_unit")


def test_divider():
    run("divider", ["divider.sv"], "test_muldiv", name="divider", testcase="iterative_divider")
