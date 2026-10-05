// The one-cycle F/D operations (combinational): sign injection, FMIN/FMAX,
// the comparisons, FCLASS and the FMV moves.  None of them rounds.
// Operand classes come from the fp_unpack instances in fpu.sv.
`include "rv_defs.svh"

module fp_misc (
    input  logic [4:0]  op,
    input  logic        dbl,
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [31:0] ia,
    input  logic        a_zero, a_inf, a_nan, a_snan, a_subnormal,
    input  logic        b_zero, b_nan, b_snan,
    output logic [63:0] result,
    output logic [31:0] iresult,
    output logic [4:0]  flags
);
    // un-boxed operands: sign and magnitude (exponent and fraction as one unsigned number)
    logic [31:0] a32, b32;
    logic        sa, sb, mag_lt, mag_eq, both_zero, any_nan, lt, eq, a_less, pick_a, sgn;
    logic [62:0] ma, mb;

    assign a32 = (&a[63:32]) ? a[31:0] : 32'h7fc0_0000;
    assign b32 = (&b[63:32]) ? b[31:0] : 32'h7fc0_0000;
    assign sa = dbl ? a[63] : a32[31];
    assign sb = dbl ? b[63] : b32[31];
    assign ma = dbl ? a[62:0] : {32'd0, a32[30:0]};
    assign mb = dbl ? b[62:0] : {32'd0, b32[30:0]};
    assign mag_lt = (ma < mb);
    assign mag_eq = (ma == mb);
    assign both_zero = a_zero && b_zero;
    assign any_nan = a_nan || b_nan;
    // ordered comparisons treat +0 and -0 as equal
    assign lt = !any_nan && !both_zero && ((sa && !sb) || (sa == sb && (sa ? (!mag_lt && !mag_eq) : mag_lt)));
    assign eq = !any_nan && (both_zero || (sa == sb && mag_eq));
    // FMIN/FMAX order -0 below +0
    assign a_less = lt || (both_zero && sa && !sb);
    assign pick_a = (op == `FOP_MAX) ? !a_less : a_less;

    always_comb begin
        case (op)
            `FOP_SGNJ:  sgn = sb;
            `FOP_SGNJN: sgn = !sb;
            default:    sgn = sa ^ sb;
        endcase
    end

    logic [63:0] mm, canon;
    assign canon = dbl ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
    always_comb begin
        // a quiet NaN loses against a number; two NaNs give the canonical NaN
        if (a_nan && b_nan) mm = canon;
        else if (a_nan) mm = dbl ? b : {32'hffff_ffff, b32};
        else if (b_nan) mm = dbl ? a : {32'hffff_ffff, a32};
        else if (pick_a) mm = dbl ? a : {32'hffff_ffff, a32};
        else mm = dbl ? b : {32'hffff_ffff, b32};
    end

    logic [9:0] cls;
    always_comb begin
        cls = 10'd0;
        if (a_snan) cls[8] = 1'b1;
        else if (a_nan) cls[9] = 1'b1;
        else if (a_inf) begin cls[0] = sa; cls[7] = !sa; end
        else if (a_zero) begin cls[3] = sa; cls[4] = !sa; end
        else if (a_subnormal) begin cls[2] = sa; cls[5] = !sa; end
        else begin cls[1] = sa; cls[6] = !sa; end
    end

    always_comb begin
        result = 64'd0;
        iresult = 32'd0;
        flags = 5'd0;
        case (op)
            `FOP_SGNJ, `FOP_SGNJN, `FOP_SGNJX:
                result = dbl ? {sgn, a[62:0]} : {32'hffff_ffff, sgn, a32[30:0]};
            `FOP_MIN, `FOP_MAX: begin
                result = mm;
                flags[`FF_NV] = a_snan || b_snan;
            end
            `FOP_EQ: begin
                iresult = {31'd0, eq};
                flags[`FF_NV] = a_snan || b_snan;      // quiet comparison
            end
            `FOP_LT: begin
                iresult = {31'd0, lt};
                flags[`FF_NV] = any_nan;               // signaling comparison
            end
            `FOP_LE: begin
                iresult = {31'd0, lt || eq};
                flags[`FF_NV] = any_nan;
            end
            `FOP_CLASS: iresult = {22'd0, cls};
            `FOP_MVXW:  iresult = a[31:0];
            `FOP_MVWX:  result = {32'hffff_ffff, ia};
            default: ;
        endcase
    end
endmodule
