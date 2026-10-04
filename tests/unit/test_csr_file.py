"""CSR file: which CSR numbers exist and which are read-only (the list must
match the golden model), read/write/set/clear semantics with the WARL
masks, trap entry and MRET, and the counters (mcycle every cycle, minstret
per retired instruction, a CSR write replacing the increment, hpm counters
per event)."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from simrun import run

EXISTING = [0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343, 0x344, 0xF11, 0xF12, 0xF13, 0xF14, 0xF15]
for base in (0xB00, 0xB80, 0xC00, 0xC80):
    EXISTING += [base + n for n in [0, 2] + list(range(3, 13))]


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for n in ("addr", "op", "src", "writes", "we", "trap", "trap_pc", "trap_cause", "trap_tval", "mret",
              "instret_inc", "events"):
        getattr(dut, n).value = 0
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def access(dut, addr, op, src, write=True):
    """One CSR instruction; returns the old value."""
    dut.addr.value, dut.op.value, dut.src.value = addr, op, src
    dut.writes.value, dut.we.value = int(write), int(write)
    await Timer(1, unit="ns")
    old = int(dut.rdata.value)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.we.value = dut.writes.value = 0
    return old


@cocotb.test()
async def csr_file(dut):
    await setup(dut)
    for a in range(0x1000):
        dut.addr.value, dut.writes.value = a, 0
        await Timer(1, unit="ns")
        assert int(dut.illegal.value) == (a not in EXISTING), f"CSR {a:#x} existence"
        dut.writes.value = 1
        await Timer(1, unit="ns")
        assert int(dut.illegal.value) == (a not in EXISTING or a >> 10 == 3), f"CSR {a:#x} writability"
    dut.writes.value = 0

    await access(dut, 0x340, 1, 0x12345678)                       # csrrw mscratch
    assert await access(dut, 0x340, 2, 0x0000000F) == 0x12345678  # csrrs
    assert await access(dut, 0x340, 3, 0x12340000) == 0x1234567F  # csrrc
    assert await access(dut, 0x340, 2, 0, write=False) == 0x0000567F
    await access(dut, 0x305, 1, 0x80000103)                       # mtvec: direct mode only
    assert int(dut.mtvec.value) == 0x80000100
    await access(dut, 0x341, 1, 0x80000007)                       # mepc: 4-byte aligned
    assert int(dut.mepc.value) == 0x80000004
    await access(dut, 0x300, 1, 0xFFFFFFFF)                       # mstatus: MIE, MPIE only
    assert await access(dut, 0x300, 1, 0x8) == 0x1888
    assert await access(dut, 0x301, 1, 0, write=False) == 0x40001100

    # trap: mepc/mcause/mtval, MIE -> MPIE; MRET restores
    dut.trap.value, dut.trap_pc.value, dut.trap_cause.value, dut.trap_tval.value = 1, 0x80000040, 2, 0xDEAD
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.trap.value = 0
    assert int(dut.mepc.value) == 0x80000040
    assert await access(dut, 0x342, 1, 0, write=False) == 2
    assert await access(dut, 0x343, 1, 0, write=False) == 0xDEAD
    assert await access(dut, 0x300, 1, 0, write=False) == 0x1880       # MIE=0, MPIE=1
    dut.mret.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.mret.value = 0
    assert await access(dut, 0x300, 1, 0, write=False) == 0x1888

    # counters
    c0 = await access(dut, 0xB00, 1, 0, write=False)
    c1 = await access(dut, 0xC00, 1, 0, write=False)
    assert c1 == c0 + 1, "mcycle counts every cycle"
    i0 = await access(dut, 0xB02, 1, 0, write=False)
    dut.instret_inc.value = 1
    dut.events.value = 0b0000010001
    for _ in range(5):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.instret_inc.value = 0
    dut.events.value = 0
    assert await access(dut, 0xB02, 1, 0, write=False) == i0 + 5
    assert await access(dut, 0xB03, 1, 0, write=False) == 5      # event 0 -> mhpmcounter3
    assert await access(dut, 0xB07, 1, 0, write=False) == 5      # event 4 -> mhpmcounter7
    assert await access(dut, 0xB04, 1, 0, write=False) == 0
    # a write to minstret replaces that cycle's increment
    dut.instret_inc.value = 1
    await access(dut, 0xB02, 1, 1000)
    dut.instret_inc.value = 0
    assert await access(dut, 0xB02, 1, 0, write=False) == 1000
    await access(dut, 0xB82, 1, 7)                               # minstreth
    assert await access(dut, 0xC82, 1, 0, write=False) == 7


def test_csr_file():
    run("csr_file", ["csr_file.sv"], "test_csr_file")
