// 32 x 64-bit floating-point register file: three asynchronous read ports
// (rs1, rs2 and, for the fused multiply-adds, rs3), one synchronous write
// port.  Unlike x0, f0 is an ordinary register.  A read of the register
// being written in the same cycle returns the new value (WB -> ID).
module fp_regfile (
    input  logic        clk,
    input  logic [4:0]  ra1,
    input  logic [4:0]  ra2,
    input  logic [4:0]  ra3,
    output logic [63:0] rd1,
    output logic [63:0] rd2,
    output logic [63:0] rd3,
    input  logic        we,
    input  logic [4:0]  wa,
    input  logic [63:0] wd
);
    logic [63:0] regs [0:31];

    always_ff @(posedge clk)
        if (we)
            regs[wa] <= wd;

    assign rd1 = (we && wa == ra1) ? wd : regs[ra1];
    assign rd2 = (we && wa == ra2) ? wd : regs[ra2];
    assign rd3 = (we && wa == ra3) ? wd : regs[ra3];
endmodule
