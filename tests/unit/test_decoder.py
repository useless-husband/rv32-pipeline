"""Decoder: every instruction class with random fields, the exact SYSTEM
encodings, and random 32-bit words, compared with a reference decoder
written here from the ISA tables.  Checks legality, the side-effect flags,
register use, the immediate and the ALU operation."""

import random

import cocotb
from cocotb.triggers import Timer

from simrun import run

ALU = {"add": 0, "sub": 1, "sll": 2, "slt": 3, "sltu": 4, "xor": 5, "srl": 6, "sra": 7, "or": 8, "and": 9}
WB_ALU, WB_MEM, WB_PC4, WB_CSR, WB_MDU = range(5)
A_RS1, A_PC, A_ZERO = range(3)


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def ref(i):
    """Expected decoder outputs for instruction word i (None = don't care)."""
    op, rd, f3, rs1, rs2, f7 = i & 0x7F, (i >> 7) & 31, (i >> 12) & 7, (i >> 15) & 31, (i >> 20) & 31, i >> 25
    imm_i = sx(i >> 20, 12)
    imm_s = sx(((i >> 25) << 5) | ((i >> 7) & 31), 12)
    imm_b = sx((((i >> 31) & 1) << 12) | (((i >> 7) & 1) << 11) | (((i >> 25) & 63) << 5) | (((i >> 8) & 15) << 1), 13)
    imm_u = i & 0xFFFFF000
    imm_j = sx((((i >> 31) & 1) << 20) | (((i >> 12) & 255) << 12) | (((i >> 20) & 1) << 11) | (((i >> 21) & 1023) << 1), 21)
    e = dict(illegal=1, writes=0, uses_rs1=0, uses_rs2=0, is_branch=0, is_jal=0, is_jalr=0, is_load=0,
             is_store=0, is_mdu=0, is_csr=0, is_ecall=0, is_ebreak=0, is_mret=0, is_fencei=0,
             wb_sel=None, alu_op=None, imm=None, a_sel=None, b_imm=None)
    if i & 3 != 3:
        return e
    if op == 0x37:
        e.update(illegal=0, writes=1, a_sel=A_ZERO, b_imm=1, imm=imm_u, alu_op=ALU["add"], wb_sel=WB_ALU)
    elif op == 0x17:
        e.update(illegal=0, writes=1, a_sel=A_PC, b_imm=1, imm=imm_u, alu_op=ALU["add"], wb_sel=WB_ALU)
    elif op == 0x6F:
        e.update(illegal=0, writes=1, is_jal=1, imm=imm_j, wb_sel=WB_PC4)
    elif op == 0x67 and f3 == 0:
        e.update(illegal=0, writes=1, is_jalr=1, uses_rs1=1, imm=imm_i, wb_sel=WB_PC4, alu_op=ALU["add"],
                 a_sel=A_RS1, b_imm=1)
    elif op == 0x63 and f3 not in (2, 3):
        e.update(illegal=0, is_branch=1, uses_rs1=1, uses_rs2=1, imm=imm_b)
    elif op == 0x03 and f3 in (0, 1, 2, 4, 5):
        e.update(illegal=0, writes=1, is_load=1, uses_rs1=1, imm=imm_i, wb_sel=WB_MEM, alu_op=ALU["add"],
                 a_sel=A_RS1, b_imm=1)
    elif op == 0x23 and f3 in (0, 1, 2):
        e.update(illegal=0, is_store=1, uses_rs1=1, uses_rs2=1, imm=imm_s, alu_op=ALU["add"], a_sel=A_RS1, b_imm=1)
    elif op == 0x13:
        names = {0: "add", 2: "slt", 3: "sltu", 4: "xor", 6: "or", 7: "and"}
        if f3 in names:
            e.update(illegal=0, alu_op=ALU[names[f3]])
        elif f3 == 1 and f7 == 0:
            e.update(illegal=0, alu_op=ALU["sll"])
        elif f3 == 5 and f7 in (0, 0x20):
            e.update(illegal=0, alu_op=ALU["sra" if f7 else "srl"])
        if not e["illegal"]:
            e.update(writes=1, uses_rs1=1, a_sel=A_RS1, b_imm=1, wb_sel=WB_ALU,
                     imm=imm_i if f3 not in (1, 5) else None)
    elif op == 0x33:
        if f7 == 1:
            e.update(illegal=0, writes=1, uses_rs1=1, uses_rs2=1, is_mdu=1, wb_sel=WB_MDU)
        elif f7 == 0 or (f7 == 0x20 and f3 in (0, 5)):
            names = ["add", "sll", "slt", "sltu", "xor", "srl", "or", "and"]
            name = "sub" if f7 and f3 == 0 else "sra" if f7 else names[f3]
            e.update(illegal=0, writes=1, uses_rs1=1, uses_rs2=1, alu_op=ALU[name], a_sel=A_RS1, b_imm=0,
                     wb_sel=WB_ALU)
    elif op == 0x0F and f3 in (0, 1):
        e.update(illegal=0, is_fencei=int(f3 == 1))
    elif op == 0x73:
        if f3 == 0:
            if i in (0x00000073, 0x00100073, 0x30200073, 0x10500073):
                e.update(illegal=0, is_ecall=int(i == 0x73), is_ebreak=int(i == 0x00100073),
                         is_mret=int(i == 0x30200073))
        elif f3 != 4:
            e.update(illegal=0, writes=1, is_csr=1, uses_rs1=int(f3 < 4), wb_sel=WB_CSR)
    e["rd_we"] = int(e["writes"] and rd != 0)
    e["is_div"] = int(e["is_mdu"] and f3 >= 4)
    e["csr_writes"] = int(e["is_csr"] and ((f3 & 3) == 1 or rs1 != 0))
    del e["writes"]
    return e


def gen(rng, n):
    """Instruction words covering every opcode, plus SYSTEM specials and junk."""
    ops = [0x37, 0x17, 0x6F, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x0F, 0x73]
    words = [0x00000073, 0x00100073, 0x30200073, 0x10500073, 0x00000013, 0, 0xFFFFFFFF]
    for _ in range(n):
        op = rng.choice(ops)
        w = rng.getrandbits(32) & ~0x7F | op
        if op in (0x13, 0x33) and rng.random() < 0.7:  # mostly valid funct7
            w = (w & 0x01FFFFFF) | (rng.choice([0, 0x20, 1, 0x20]) << 25)
        words.append(w)
    words += [rng.getrandbits(32) for _ in range(n // 4)]
    return words


@cocotb.test()
async def decoder_matches_reference(dut):
    rng = random.Random(5)
    for w in gen(rng, 6000):
        dut.insn.value = w
        await Timer(1, unit="ns")
        exp = ref(w)
        for k, v in exp.items():
            if v is None:
                continue
            got = int(getattr(dut, k).value)
            if k == "imm":
                v &= 0xFFFFFFFF
            assert got == v, f"insn {w:#010x}: {k} = {got:#x}, expected {v:#x}"
        if not exp["illegal"]:
            assert int(dut.rd.value) == (w >> 7) & 31
            assert int(dut.rs1.value) == (w >> 15) & 31
            assert int(dut.rs2.value) == (w >> 20) & 31


def test_decoder():
    run("decoder", ["decoder.sv"], "test_decoder")
