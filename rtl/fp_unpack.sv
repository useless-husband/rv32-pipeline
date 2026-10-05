// Unpacks one floating-point register value into sign, unbiased exponent and
// a 53-bit significand, in single or double format (combinational).
//
// Both formats share one internal form: value = sig * 2^(exp - 52), the
// hidden bit at sig[52].  A single's 24-bit significand sits in the top 24
// bits of `sig` (29 zeros below), so the double-width datapaths compute on
// it unchanged and only the rounder needs to know the format.  Subnormals
// keep exp = emin with the hidden bit clear (they are not normalised here).
//
// A single must be NaN-boxed (upper 32 bits all ones); any other pattern
// read as a single is the canonical quiet NaN.
module fp_unpack (
    input  logic [63:0] x,
    input  logic        dbl,
    output logic        sign,
    output logic signed [12:0] exp,
    output logic [52:0] sig,
    output logic        is_zero,
    output logic        is_inf,
    output logic        is_nan,
    output logic        is_snan
);
    logic [31:0] s32;
    logic [10:0] ef;
    logic [51:0] fr;
    logic        e_zero, e_ones;

    assign s32 = (&x[63:32]) ? x[31:0] : 32'h7fc0_0000;

    always_comb begin
        if (dbl) begin
            sign = x[63];
            ef = x[62:52];
            fr = x[51:0];
            e_zero = (x[62:52] == 11'd0);
            e_ones = (&x[62:52]);
            exp = e_zero ? -13'sd1022 : $signed({2'b00, ef}) - 13'sd1023;
        end else begin
            sign = s32[31];
            ef = {3'b000, s32[30:23]};
            fr = {s32[22:0], 29'd0};
            e_zero = (s32[30:23] == 8'd0);
            e_ones = (&s32[30:23]);
            exp = e_zero ? -13'sd126 : $signed({2'b00, ef}) - 13'sd127;
        end
    end

    assign sig = {!e_zero, fr};
    assign is_zero = e_zero && (fr == 52'd0);
    assign is_inf = e_ones && (fr == 52'd0);
    assign is_nan = e_ones && (fr != 52'd0);
    assign is_snan = is_nan && !fr[51];
endmodule
