"""Python reference functions for the unit tests (written from the ISA
specification, independently of the RTL)."""

M32 = 0xFFFFFFFF


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def alu(op, a, b):
    sh = b & 31
    return {
        "add": a + b, "sub": a - b, "sll": a << sh, "slt": int(s32(a) < s32(b)),
        "sltu": int((a & M32) < (b & M32)), "xor": a ^ b, "srl": (a & M32) >> sh,
        "sra": s32(a) >> sh, "or": a | b, "and": a & b,
    }[op] & M32


def muldiv(f3, a, b):
    sa, sb = s32(a), s32(b)
    if f3 == 0:
        return (a * b) & M32
    if f3 == 1:
        return ((sa * sb) >> 32) & M32
    if f3 == 2:
        return ((sa * (b & M32)) >> 32) & M32
    if f3 == 3:
        return ((a * b) >> 32) & M32
    if f3 == 4:
        if b == 0:
            return M32
        if sa == -(1 << 31) and sb == -1:
            return a
        q = abs(sa) // abs(sb)
        return (-q if (sa < 0) != (sb < 0) else q) & M32
    if f3 == 5:
        return M32 if b == 0 else a // b
    if f3 == 6:
        if b == 0:
            return a
        if sa == -(1 << 31) and sb == -1:
            return 0
        r = abs(sa) % abs(sb)
        return (-r if sa < 0 else r) & M32
    return a if b == 0 else a % b


EDGE = [0, 1, 2, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 0x0000FFFF, 0xFFFF0000,
        31, 32, 33]
