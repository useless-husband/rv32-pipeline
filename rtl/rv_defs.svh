// Shared constants.  Kept as `define macros (no SystemVerilog packages) so
// the same sources work with Verilator 5.020+, Icarus Verilog 12+ and Yosys.
`ifndef RV_DEFS_SVH
`define RV_DEFS_SVH

// ALU operations
`define ALU_ADD   4'd0
`define ALU_SUB   4'd1
`define ALU_SLL   4'd2
`define ALU_SLT   4'd3
`define ALU_SLTU  4'd4
`define ALU_XOR   4'd5
`define ALU_SRL   4'd6
`define ALU_SRA   4'd7
`define ALU_OR    4'd8
`define ALU_AND   4'd9

// ALU operand A
`define A_RS1     2'd0
`define A_PC      2'd1
`define A_ZERO    2'd2

// value written to rd
`define WB_ALU    3'd0
`define WB_MEM    3'd1
`define WB_PC4    3'd2
`define WB_CSR    3'd3
`define WB_MDU    3'd4

// exception causes (mcause)
`define CAUSE_MISALIGNED_FETCH 32'd0
`define CAUSE_ILLEGAL          32'd2
`define CAUSE_BREAKPOINT       32'd3
`define CAUSE_MISALIGNED_LOAD  32'd4
`define CAUSE_MISALIGNED_STORE 32'd6
`define CAUSE_ECALL_M          32'd11

// platform (same numbers as model/rv_platform.h)
`define RESET_PC     32'h8000_0000
`define RAM_BASE     32'h8000_0000
`define RAM_BYTES    32'h0010_0000
`define MMIO_CONSOLE 32'h1000_0000
`define MMIO_EXIT    32'h1000_0004

// performance events (mhpmcounter3 + index), same order as RV_HPM_NAMES
`define NUM_EVENTS        10
`define EV_ICACHE_MISS    0
`define EV_DCACHE_ACCESS  1
`define EV_DCACHE_MISS    2
`define EV_DCACHE_WB      3
`define EV_BRANCH         4
`define EV_BRANCH_MISS    5
`define EV_JUMP           6
`define EV_JUMP_MISS      7
`define EV_LOAD_USE       8
`define EV_ICACHE_ACCESS  9

`endif
