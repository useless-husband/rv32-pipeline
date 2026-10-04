"""I-cache and D-cache, each driven the way the pipeline drives it (the
array read address is given one cycle early) and backed by a Python bus
memory with latency.

I-cache: every delivered instruction word is correct, the miss count equals
a Python direct-mapped model's, a fetch killed by a redirect starts no
refill, and FENCE.I invalidation forces the next fetch to miss.

D-cache: random loads and stores (byte/half/word, I/O addresses, store
followed by a load of the same word, bubbles between accesses) return the
values of a flat reference memory; the miss and write-back counts equal a
Python model of a 2-way LRU write-back cache; after a flush, memory holds
exactly what the reference holds."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from simrun import run

LAT = 3
SETS = 8


class BusMemory:
    """Line-based bus slave: ack LAT cycles after a request, as rtl/sim/mem_model.sv."""

    def __init__(self, dut, rng):
        self.dut, self.rng = dut, rng
        self.lines = {}
        self.io_writes = []
        self.requests = 0

    def line(self, a):
        a &= ~15
        if a not in self.lines:
            self.lines[a] = bytearray(self.rng.getrandbits(8) for _ in range(16))
        return self.lines[a]

    def word(self, a):
        return int.from_bytes(self.line(a)[a & 12:(a & 12) + 4], "little")

    async def serve(self):
        d = self.dut
        d.bus_ack.value = 0
        d.bus_rdata.value = 0
        while True:
            await FallingEdge(d.clk)
            d.bus_ack.value = 0
            if not int(d.bus_req.value):
                continue
            self.requests += 1
            addr = int(d.bus_addr.value)
            we = int(d.bus_we.value) if hasattr(d, "bus_we") else 0
            for _ in range(LAT - 1):
                await FallingEdge(d.clk)
            if addr >> 31:
                ln = self.line(addr)
                d.bus_rdata.value = int.from_bytes(ln, "little")
                if we:
                    data, strb = int(d.bus_wdata.value).to_bytes(16, "little"), int(d.bus_wstrb.value)
                    for b in range(16):
                        if strb >> b & 1:
                            ln[b] = data[b]
            else:
                d.bus_rdata.value = 0
                if we:
                    self.io_writes.append((addr, int(d.bus_wdata.value), int(d.bus_wstrb.value)))
            d.bus_ack.value = 1


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


# ------------------------------------------------------------------ I-cache
def fetch_stream(rng, n):
    pcs, pc = [], 0x80000000
    hot = [0x80000000 + 4 * rng.randrange(2048) for _ in range(12)]
    while len(pcs) < n:
        for _ in range(rng.randint(1, 12)):
            pcs.append(pc)
            pc += 4
        pc = rng.choice(hot) if rng.random() < 0.8 else 0x80000000 + 4 * rng.randrange(1 << 14)
    return pcs[:n]


@cocotb.test()
async def icache(dut):
    rng = random.Random(7)
    mem = BusMemory(dut, rng)
    dut.kill.value, dut.inv_req.value = 0, 0
    pcs = fetch_stream(rng, 3000)
    dut.addr_next.value, dut.addr.value = pcs[0], pcs[0]
    await start(dut)
    cocotb.start_soon(mem.serve())
    model, model_misses, misses, i = {}, 0, 0, 0
    rtl_missed = False
    pending_inv = False
    while i < len(pcs):
        pc = pcs[i]
        dut.addr.value, dut.addr_next.value = pc, pc
        dut.inv_req.value = int(pending_inv)
        await Timer(1, unit="ns")
        misses += int(dut.ev_miss.value)
        if pending_inv:
            if int(dut.inv_done.value):
                pending_inv = False
                model.clear()
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            continue
        if int(dut.ev_miss.value):
            rtl_missed = True
        if int(dut.hit.value):
            assert int(dut.insn.value) == mem.word(pc), f"wrong instruction at {pc:#x}"
            s, t = (pc >> 4) % SETS, pc >> 4 >> (SETS.bit_length() - 1)
            mm = model.get(s) != t
            if mm:
                model_misses += 1
                model[s] = t
            assert mm == rtl_missed, f"fetch {i} ({pc:#x}): model miss {mm}, cache miss {rtl_missed}"
            rtl_missed = False
            i += 1
            if i < len(pcs):
                dut.addr_next.value = pcs[i]
            if i % 500 == 0:
                pending_inv = True
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
    assert misses == model_misses, f"{misses} misses, direct-mapped model says {model_misses}"

    # a fetch that is being killed in the same cycle must not start a refill
    before = mem.requests
    far = 0x80100000
    dut.addr.value, dut.addr_next.value, dut.kill.value = far, far + 64, 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.kill.value = 0
    dut.addr.value = far + 64
    for _ in range(LAT + 2):
        await FallingEdge(dut.clk)
    assert mem.requests == before + 1, "killed fetch started a refill"


def test_icache():
    run("icache", ["icache.sv"], "test_caches", parameters={"SETS": SETS}, name="icache", testcase="icache")


# ------------------------------------------------------------------ D-cache
class LruModel:
    def __init__(self):
        self.sets = [[None, None] for _ in range(SETS)]   # [tag, dirty]
        self.lru = [0] * SETS
        self.misses = self.writebacks = 0

    def access(self, addr, store):
        s, t = (addr >> 4) % SETS, addr >> 4 >> (SETS.bit_length() - 1)
        ways = self.sets[s]
        for w in (0, 1):
            if ways[w] and ways[w][0] == t:
                break
        else:
            self.misses += 1
            w = 0 if ways[0] is None else 1 if ways[1] is None else self.lru[s]
            if ways[w] and ways[w][1]:
                self.writebacks += 1
            ways[w] = [t, False]
        if store:
            ways[w][1] = True
        self.lru[s] = 1 - w


def dcache_ops(rng, n):
    lines = [0x80000000 + tag * SETS * 16 + s * 16 for tag in range(6) for s in range(4)]
    ops = []
    while len(ops) < n:
        if rng.random() < 0.1:
            ops.append(("idle",))
            continue
        size = rng.choice([1, 2, 4])
        io = rng.random() < 0.05
        base = 0x10000000 if io else rng.choice(lines)
        addr = base + rng.randrange(0, 16, size)
        store = rng.random() < 0.5
        ops.append(("st" if store else "ld", addr, size, rng.getrandbits(32)))
        if store and rng.random() < 0.3:
            ops.append(("ld", addr & ~3, 4, 0))
    return ops


@cocotb.test()
async def dcache(dut):
    rng = random.Random(8)
    mem = BusMemory(dut, rng)
    ref = {}
    model = LruModel()

    def ref_word(a):
        a &= ~3
        if a not in ref:
            ref[a] = mem.word(a) if a >> 31 else 0
        return ref[a]

    for name in ("req", "we", "addr", "wdata", "wmask", "flush_req"):
        getattr(dut, name).value = 0
    ops = dcache_ops(rng, 3000)
    dut.addr_next.value = 0x80000000
    await start(dut)
    cocotb.start_soon(mem.serve())
    misses = wbs = 0
    io_expected = []
    i = 0
    while i < len(ops):
        op = ops[i]
        nxt = next((o for o in ops[i + 1:] if o[0] != "idle"), None)
        if op[0] == "idle":
            dut.req.value = 0
            dut.addr_next.value = nxt[1] if i + 1 < len(ops) and ops[i + 1][0] != "idle" else rng.getrandbits(32)
            i += 1
            await Timer(1, unit="ns")
            wbs += int(dut.ev_wb.value)
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            continue
        kind, addr, size, value = op
        lane = addr & 3
        data = {1: (value & 0xFF) * 0x01010101, 2: (value & 0xFFFF) * 0x00010001, 4: value}[size]
        mask = ((1 << size) - 1) << lane
        dut.req.value, dut.we.value, dut.addr.value = 1, int(kind == "st"), addr
        dut.wdata.value, dut.wmask.value = data, mask
        dut.addr_next.value = addr
        await Timer(1, unit="ns")
        misses += int(dut.ev_miss.value)
        if int(dut.ready.value):
            if kind == "ld":
                got = int(dut.rdata.value)
                assert got == ref_word(addr), f"op {i}: load {addr:#x} = {got:#x}, want {ref_word(addr):#x}"
            else:
                old = ref_word(addr)
                bm = sum(0xFF << (8 * b) for b in range(4) if mask >> b & 1)
                if addr >> 31:
                    ref[addr & ~3] = (old & ~bm) | (data & bm)
                else:
                    io_expected.append((addr & ~15, data, mask << (4 * ((addr >> 2) & 3))))
            if addr >> 31:
                model.access(addr, kind == "st")
            i += 1
            if nxt and i < len(ops) and ops[i][0] != "idle":
                dut.addr_next.value = nxt[1]
        wbs += int(dut.ev_wb.value)
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
    assert misses == model.misses, f"{misses} misses, 2-way LRU model says {model.misses}"
    assert wbs == model.writebacks, f"{wbs} write-backs, model says {model.writebacks}"
    assert [(a, s) for a, _, s in mem.io_writes] == [(a, s) for a, _, s in io_expected]

    # flush: afterwards memory equals the reference
    dut.req.value, dut.flush_req.value = 0, 1
    for _ in range(SETS * 2 * (LAT + 4) + 10):
        await FallingEdge(dut.clk)
        if int(dut.flush_done.value):
            break
    else:
        assert False, "flush never finished"
    dut.flush_req.value = 0
    await FallingEdge(dut.clk)
    for a, v in ref.items():
        if a >> 31:
            assert mem.word(a) == v, f"after flush memory[{a:#x}] = {mem.word(a):#x}, want {v:#x}"


def test_dcache():
    run("dcache", ["dcache.sv"], "test_caches", parameters={"SETS": SETS}, name="dcache", testcase="dcache")
