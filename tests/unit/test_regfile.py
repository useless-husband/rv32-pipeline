"""Register file: random writes and reads against a Python model, x0 stays
zero, and the WB->ID bypass (BYPASS=1) returns the value being written."""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from simrun import run


@cocotb.test()
async def regfile_random(dut):
    bypass = int(os.environ.get("RF_BYPASS", "0"))
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(2)
    model = [0] * 32
    # initialise every register so the model and the RTL agree
    for r in range(32):
        await FallingEdge(dut.clk)
        dut.we.value, dut.wa.value, dut.wd.value = 1, r, 0
    for _ in range(3000):
        await FallingEdge(dut.clk)
        we, wa, wd = rng.random() < 0.7, rng.randrange(32), rng.getrandbits(32)
        ra1, ra2 = rng.randrange(32), rng.choice([wa, rng.randrange(32)])
        dut.we.value, dut.wa.value, dut.wd.value = int(we), wa, wd
        dut.ra1.value, dut.ra2.value = ra1, ra2
        await Timer(1, unit="ns")
        for ra, port in ((ra1, dut.rd1), (ra2, dut.rd2)):
            exp = model[ra]
            if bypass and we and wa == ra and ra != 0:
                exp = wd
            assert int(port.value) == exp, f"read x{ra}: got {int(port.value):#x}, want {exp:#x}"
        await RisingEdge(dut.clk)
        if we and wa:
            model[wa] = wd


def test_regfile_plain():
    os.environ["RF_BYPASS"] = "0"
    run("regfile", ["regfile.sv"], "test_regfile", parameters={"BYPASS": 0}, name="regfile_plain")


def test_regfile_bypass():
    os.environ["RF_BYPASS"] = "1"
    run("regfile", ["regfile.sv"], "test_regfile", parameters={"BYPASS": 1}, name="regfile_bypass")
