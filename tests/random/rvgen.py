#!/usr/bin/env python3
"""Random RV32IM instruction-stream generator for lockstep testing.

The programs are not checked against expected values: the simulator runs
them on a core in lockstep with the golden model, which compares every
committed instruction.  So the generator only has to produce programs that
terminate and that stress the places where pipelines go wrong:

* back-to-back dependencies (sources are drawn mostly from the last few
  destinations), load-use pairs, stores followed by loads of the same word;
* branches and jumps with loads, stores, divides and CSR accesses in their
  shadow (the instructions after a taken branch must be squashed);
* short backward loops (the predictor learns, then mispredicts the exit);
* memory accesses spread at 2 KiB strides, which all land in the same
  D-cache set and force conflict misses and dirty write-backs;
* divide edge cases (0, -1, INT_MIN), counter and CSR reads/writes, traps
  (ECALL, EBREAK, illegal instructions, misaligned loads/stores/jumps; the
  handler skips the instruction), uncached I/O accesses, and self-modifying
  code made visible with FENCE.I.

Register use: x1-x27 random; x28 loop counter; x29 address scratch;
x30 trap-handler scratch; x31 data base pointer.

Usage: rvgen.py --seed N [--length N] -o out.S
"""

import argparse
import random

WORK = list(range(1, 28))
DATA_BYTES = 16384
ALU_RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
ALU_RI = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I = ["slli", "srli", "srai"]
MULDIV = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
BRANCH = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = [("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]
SPECIAL = [0, 1, -1, 0x7FFFFFFF, -0x80000000, 0x80000000 - 1, 2, -2, 0xFFFF, 0x8000]


def addi_encoding(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13


class Gen:
    def __init__(self, seed, length):
        self.r = random.Random(seed)
        self.seed = seed
        self.length = length
        self.out = []
        self.recent = []
        self.label = 0
        self.count = 0

    # -- helpers -----------------------------------------------------------
    def emit(self, s):
        self.out.append("    " + s)
        self.count += 1

    def lab(self):
        self.label += 1
        return f"L{self.label}"

    def dst(self, avoid=()):
        while True:
            d = self.r.choice(WORK)
            if d not in avoid:
                break
        self.recent = ([d] + self.recent)[:4]
        return d

    def src(self):
        if self.recent and self.r.random() < 0.6:
            return self.r.choice(self.recent)
        return self.r.choice([0] + WORK)

    def imm12(self):
        return self.r.choice([0, 1, -1, 2047, -2048, self.r.randint(-2048, 2047)])

    # -- instruction groups --------------------------------------------------
    def alu(self):
        k = self.r.random()
        if k < 0.45:
            self.emit(f"{self.r.choice(ALU_RR)} x{self.dst()}, x{self.src()}, x{self.src()}")
        elif k < 0.75:
            self.emit(f"{self.r.choice(ALU_RI)} x{self.dst()}, x{self.src()}, {self.imm12()}")
        elif k < 0.9:
            self.emit(f"{self.r.choice(SHIFT_I)} x{self.dst()}, x{self.src()}, {self.r.randint(0, 31)}")
        elif k < 0.95:
            self.emit(f"lui x{self.dst()}, {self.r.randint(0, 0xFFFFF)}")
        else:
            self.emit(f"auipc x{self.dst()}, {self.r.randint(0, 0xFFFFF)}")

    def muldiv(self):
        if self.r.random() < 0.3:  # edge-case operands
            a, b = self.dst(), self.dst()
            self.emit(f"li x{a}, {self.r.choice(SPECIAL)}")
            self.emit(f"li x{b}, {self.r.choice(SPECIAL)}")
            self.emit(f"{self.r.choice(MULDIV)} x{self.dst()}, x{a}, x{b}")
        else:
            self.emit(f"{self.r.choice(MULDIV)} x{self.dst()}, x{self.src()}, x{self.src()}")

    def base(self):
        """Pick a base register: x31 (middle of the data) or x29 loaded with
        one of eight addresses 2 KiB apart (same D-cache set)."""
        if self.r.random() < 0.5:
            return 31, self.r.randint(-2048, 2040)
        self.emit(f"la x29, data + {self.r.randrange(8) * 2048}")
        return 29, self.r.randint(0, 2040)

    def mem(self):
        b, off = self.base()
        if self.r.random() < 0.04:  # misaligned: traps, the handler skips it
            off |= 1
        else:
            off &= ~3
        if self.r.random() < 0.5:
            op, size = self.r.choice(STORES)
            if off % size and self.r.random() < 0.5:
                off -= off % size
            self.emit(f"{op} x{self.src()}, {off}(x{b})")
            if self.r.random() < 0.3:  # load the same place right after the store
                lop, lsize = self.r.choice(LOADS)
                self.emit(f"{lop} x{self.dst()}, {off - off % lsize}(x{b})")
        else:
            op, size = self.r.choice(LOADS)
            if off % size and self.r.random() < 0.5:
                off -= off % size
            d = self.dst()
            self.emit(f"{op} x{d}, {off}(x{b})")
            if self.r.random() < 0.5:  # load-use
                self.emit(f"{self.r.choice(ALU_RR)} x{self.dst()}, x{d}, x{self.src()}")

    def shadow(self, n):
        for _ in range(n):
            self.r.choice([self.alu, self.alu, self.mem, self.muldiv, self.csr])()

    def branch(self):
        target = self.lab()
        self.emit(f"{self.r.choice(BRANCH)} x{self.src()}, x{self.src()}, {target}")
        self.shadow(self.r.randint(1, 4))
        self.out.append(f"{target}:")

    def jump(self):
        target = self.lab()
        k = self.r.random()
        if k < 0.4:
            self.emit(f"jal x{self.dst()}, {target}")
        elif k < 0.9:
            off = self.r.choice([0, 4, 8, -4])
            self.emit(f"la x29, {target} - {off}")
            self.emit(f"jalr x{self.dst()}, {off}(x29)")
        else:  # misaligned target: traps on the jump, the handler skips it
            self.emit(f"la x29, {target}")
            self.emit(f"jalr x{self.dst()}, 2(x29)")
        self.shadow(self.r.randint(1, 3))
        self.out.append(f"{target}:")

    def loop(self):
        top = self.lab()
        self.emit(f"li x28, {self.r.randint(2, 12)}")
        self.out.append(f"{top}:")
        for _ in range(self.r.randint(2, 6)):
            self.r.choice([self.alu, self.alu, self.mem, self.muldiv])()
        if self.r.random() < 0.5:
            self.branch()
        self.emit("addi x28, x28, -1")
        self.emit(f"bnez x28, {top}")

    def csr(self):
        k = self.r.random()
        if k < 0.3:
            self.emit(f"csrr x{self.dst()}, minstret")
        elif k < 0.4:
            self.emit(f"csrr x{self.dst()}, {self.r.choice(['mcycle', 'cycle', 'mhpmcounter5', 'instreth'])}")
        elif k < 0.8:
            op = self.r.choice(["csrrw", "csrrs", "csrrc"])
            # mepc/mcause/mtval are free to use: the trap handler rewrites them
            csr = self.r.choice(["mscratch", "mscratch", "mepc", "mcause", "mtval"])
            self.emit(f"{op} x{self.dst()}, {csr}, x{self.src()}")
        else:
            op = self.r.choice(["csrrwi", "csrrsi", "csrrci"])
            self.emit(f"{op} x{self.dst()}, mscratch, {self.r.randint(0, 31)}")

    def trap(self):
        self.emit(self.r.choice(["ecall", "ebreak", ".word 0x00000000", ".word 0xffffffff",
                                 "csrw cycle, x1", "csrr x5, 0x7c0", ".word 0x02000033 | (1 << 30)",
                                 ".word 0x00002063  # branch with reserved funct3",
                                 ".word 0x00003003  # LD (RV64 only)"]))

    def io(self):
        self.emit(f"li x29, {0x10000000}")
        if self.r.random() < 0.8:
            self.emit(f"sb x{self.src()}, 0(x29)")
        else:
            self.emit(f"lw x{self.dst()}, 0(x29)")

    def selfmod(self):
        target = self.lab()
        rd = self.dst()
        enc = addi_encoding(rd, self.src(), self.r.randint(-2048, 2047))
        self.emit(f"la x29, {target}")
        self.emit(f"li x30, {enc}")
        self.emit("sw x30, 0(x29)")
        self.emit("fence.i")
        self.out.append(f"{target}:")
        self.emit("nop  # replaced at run time")

    # -- program ---------------------------------------------------------------
    def program(self):
        self.out += [
            f"# generated by tests/random/rvgen.py --seed {self.seed} --length {self.length}",
            '#include "rv_platform.h"',
            "    .section .text.init",
            "    .globl _start",
            "_start:",
            "    la x30, trap_handler",
            "    csrw mtvec, x30",
            "    la x31, data + 8192",
        ]
        for reg in WORK:
            self.emit(f"li x{reg}, {self.r.choice(SPECIAL + [self.r.getrandbits(32)] * 4)}")
        groups = [(self.alu, 30), (self.mem, 22), (self.muldiv, 6), (self.branch, 10), (self.jump, 5),
                  (self.loop, 4), (self.csr, 5), (self.trap, 2), (self.io, 2), (self.selfmod, 1)]
        funcs = [g for g, _ in groups]
        weights = [w for _, w in groups]
        while self.count < self.length:
            self.r.choices(funcs, weights)[0]()
        self.out += [
            "    li x29, RV_MMIO_EXIT",
            "    li x30, 1",
            "    sw x30, 0(x29)",
            "1:  j 1b",
            "",
            "    .align 2",
            "trap_handler:",
            "    csrr x30, mcause",
            "    csrr x30, mtval",
            "    csrr x30, mepc",
            "    addi x30, x30, 4",
            "    csrw mepc, x30",
            "    mret",
            "",
            "    .data",
            "    .align 4",
            "data:",
        ]
        for i in range(0, DATA_BYTES // 4, 8):
            words = ", ".join(f"0x{self.r.getrandbits(32):08x}" for _ in range(8))
            self.out.append(f"    .word {words}")
        return "\n".join(self.out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--length", type=int, default=3000, help="approximate instruction count")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    with open(a.output, "w") as f:
        f.write(Gen(a.seed, a.length).program())


if __name__ == "__main__":
    main()
