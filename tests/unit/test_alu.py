"""ALU: every operation on edge-case operand pairs and on random operands,
compared with the Python reference."""

import random

import cocotb
from cocotb.triggers import Timer

from rvref import EDGE, alu
from simrun import run

OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]  # encodings 0..9


@cocotb.test()
async def alu_matches_reference(dut):
    rng = random.Random(1)
    pairs = [(a, b) for a in EDGE for b in EDGE] + \
            [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(300)]
    for code, op in enumerate(OPS):
        for a, b in pairs:
            dut.op.value = code
            dut.a.value = a
            dut.b.value = b
            await Timer(1, unit="ns")
            got = int(dut.y.value)
            assert got == alu(op, a, b), f"{op} {a:#x} {b:#x}: got {got:#x}"


def test_alu():
    run("alu", ["alu.sv"], "test_alu")
