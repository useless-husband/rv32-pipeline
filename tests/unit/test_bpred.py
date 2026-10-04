"""Branch predictor: a loop branch is learned (predicted taken after two
taken outcomes, not taken after the exit), jumps are predicted from the
BTB, tags keep aliasing PCs apart, ENABLE=0 never predicts taken, and a
long random update stream matches a Python model of the BTB + 2-bit
counters cycle by cycle."""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from simrun import run

BTB, BHT = 16, 64  # small tables so the random test sees conflicts


class Model:
    def __init__(self):
        self.btb = [None] * BTB      # (tag, target, jump)
        self.bht = [1] * BHT

    def predict(self, pc):
        i, h = (pc >> 2) % BTB, (pc >> 2) % BHT
        e = self.btb[i]
        if e and e[0] == pc >> (2 + BTB.bit_length() - 1):
            return (e[2] or self.bht[h] >= 2), e[1]
        return False, None

    def update(self, pc, branch, jump, taken, target):
        i, h = (pc >> 2) % BTB, (pc >> 2) % BHT
        if branch:
            self.bht[h] = min(3, self.bht[h] + 1) if taken else max(0, self.bht[h] - 1)
        if taken and (branch or jump):
            self.btb[i] = (pc >> (2 + BTB.bit_length() - 1), target, jump)


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value, dut.upd_valid.value, dut.pc.value = 1, 0, 0
    for name in ("upd_branch", "upd_jump", "upd_call", "upd_ret", "upd_pc", "upd_taken", "upd_target"):
        getattr(dut, name).value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def update(dut, pc, branch, jump, taken, target, call=0, ret=0):
    dut.upd_valid.value, dut.upd_pc.value, dut.upd_branch.value = 1, pc, int(branch)
    dut.upd_jump.value, dut.upd_taken.value, dut.upd_target.value = int(jump), int(taken), target
    dut.upd_call.value, dut.upd_ret.value = call, ret
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.upd_valid.value = dut.upd_call.value = dut.upd_ret.value = 0


async def predict(dut, pc):
    dut.pc.value = pc
    await Timer(1, unit="ns")
    taken = int(dut.pred_taken.value)
    target = dut.pred_target.value
    return taken, (int(target) if target.is_resolvable else None)


@cocotb.test()
async def directed(dut):
    enabled = int(os.environ.get("BP_ENABLE", "1"))
    await reset(dut)
    loop_pc, top = 0x80000100, 0x800000C0
    assert (await predict(dut, loop_pc))[0] == 0, "cold predictor must say not taken"
    await update(dut, loop_pc, 1, 0, 1, top)          # counter 1 -> 2, BTB filled
    taken, target = await predict(dut, loop_pc)
    assert taken == enabled and (not enabled or target == top)
    await update(dut, loop_pc, 1, 0, 1, top)          # -> 3
    await update(dut, loop_pc, 1, 0, 0, top)          # loop exit -> 2: still taken (hysteresis)
    assert (await predict(dut, loop_pc))[0] == enabled
    await update(dut, loop_pc, 1, 0, 0, top)          # -> 1: not taken
    assert (await predict(dut, loop_pc))[0] == 0
    # a jump is always predicted taken once it is in the BTB
    await update(dut, 0x80000200, 0, 1, 1, 0x80004000)
    assert await predict(dut, 0x80000200) == (enabled, 0x80004000)
    # same BTB index, different tag: no prediction
    alias = 0x80000200 + BTB * 4 * 1024
    assert (await predict(dut, alias))[0] == 0


@cocotb.test()
async def return_stack(dut):
    """Nested calls from different sites: each return is predicted to its own
    call site's pc+4 (the BTB alone would give the last target); with the
    stack empty the BTB target is used."""
    if not int(os.environ.get("BP_ENABLE", "1")):
        return
    await reset(dut)
    ret_pc = 0x80001000                              # the callee's RET (BTB index 0)
    sites = [0x80000104, 0x80000208, 0x8000030C]     # call sites (BTB indexes 1, 2, 3)
    await update(dut, ret_pc, 0, 1, 1, 0x80000044, ret=1)   # BTB learns: a return
    for s in sites:
        await update(dut, s, 0, 1, 1, 0x80000F00, call=1)   # nested calls push s+4
    for s in reversed(sites):
        taken, target = await predict(dut, ret_pc)
        assert taken == 1 and target == s + 4, f"return predicted to {target:#x}, want {s + 4:#x}"
        await update(dut, ret_pc, 0, 1, 1, s + 4, ret=1)    # resolves: pop
    taken, target = await predict(dut, ret_pc)
    assert taken == 1 and target == sites[0] + 4, "empty stack: BTB target"


@cocotb.test()
async def random_stream(dut):
    if not int(os.environ.get("BP_ENABLE", "1")):
        return
    await reset(dut)
    rng = random.Random(6)
    m = Model()
    pcs = [0x80000000 + 4 * rng.randrange(4096) for _ in range(40)]
    for _ in range(4000):
        pc = rng.choice(pcs)
        exp_taken, exp_target = m.predict(pc)
        taken, target = await predict(dut, pc)
        assert taken == int(exp_taken), f"pc {pc:#x}: predicted {taken}, model {exp_taken}"
        if exp_taken:
            assert target == exp_target
        kind = rng.random()
        branch, jump = kind < 0.8, kind >= 0.8
        outcome = rng.random() < (0.9 if pc % 3 else 0.2) or jump
        tgt = (pc + 4 * rng.randint(-64, 64)) & 0xFFFFFFFC
        m.update(pc, branch, jump, outcome, tgt)
        await update(dut, pc, branch, jump, outcome, tgt)


def test_bpred():
    os.environ["BP_ENABLE"] = "1"
    run("bpred", ["bpred.sv"], "test_bpred", parameters={"BTB_ENTRIES": BTB, "BHT_ENTRIES": BHT},
        name="bpred")


def test_bpred_disabled():
    os.environ["BP_ENABLE"] = "0"
    run("bpred", ["bpred.sv"], "test_bpred", parameters={"BTB_ENTRIES": BTB, "BHT_ENTRIES": BHT, "ENABLE": 0},
        name="bpred_off")
