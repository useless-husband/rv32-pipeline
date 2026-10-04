// M extension, fully combinational (used by the single-cycle core).
// funct3: 0 MUL, 1 MULH, 2 MULHSU, 3 MULHU, 4 DIV, 5 DIVU, 6 REM, 7 REMU.
// Division works on magnitudes and fixes the sign afterwards, which also
// gives the ISA's results for INT_MIN / -1 without a special case.
module muldiv_comb (
    input  logic [2:0]  op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);
    logic signed [32:0] ma, mb;
    logic signed [65:0] prod;
    logic sgn, a_neg, b_neg;
    logic [31:0] ua, ub, q, r;

    assign ma = {(op[1:0] != 2'b11) & a[31], a};       // MULHU: a unsigned
    assign mb = {(op[1:0] == 2'b01 || op[1:0] == 2'b00) & b[31], b}; // MULHSU/MULHU: b unsigned
    assign prod = ma * mb;

    assign sgn = !op[0];                                // DIV, REM are signed
    assign a_neg = sgn & a[31];
    assign b_neg = sgn & b[31];
    assign ua = a_neg ? -a : a;
    assign ub = b_neg ? -b : b;
    assign q = (ub == 32'd0) ? 32'hffff_ffff : ua / ub;
    assign r = (ub == 32'd0) ? ua : ua % ub;

    always_comb begin
        case (op)
            3'd0: y = prod[31:0];
            3'd1, 3'd2, 3'd3: y = prod[63:32];
            3'd4, 3'd5: y = (b == 32'd0) ? 32'hffff_ffff : ((a_neg ^ b_neg) ? -q : q);
            default: y = (b == 32'd0) ? a : (a_neg ? -r : r);
        endcase
    end

    logic unused;
    assign unused = &{1'b0, prod[65:64]};
endmodule
