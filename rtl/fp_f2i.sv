// Float to 32-bit integer (FCVT.W, FCVT.WU), combinational.  The
// significand is shifted so the binary point sits below bit 53, the
// fraction is rounded in the requested mode, and anything that does not fit
// (too large, NaN, infinity, a negative value for the unsigned form) raises
// invalid and saturates as the RISC-V specification lists.
`include "rv_defs.svh"

module fp_f2i (
    input  logic        is_unsigned,
    input  logic [2:0]  rm,
    input  logic        sign,
    input  logic signed [12:0] exp,
    input  logic [52:0] sig,
    input  logic        is_zero,
    input  logic        is_inf,
    input  logic        is_nan,
    output logic [31:0] result,
    output logic [4:0]  flags
);
    logic        huge_mag, tiny_mag;
    logic [5:0]  sh;
    logic [84:0] t;
    logic [31:0] ipart;
    logic        g, s, up;
    logic [32:0] mag;

    assign huge_mag = (exp >= 13'sd32);       // magnitude at least 2^32
    assign tiny_mag = (exp < -13'sd1);      // magnitude below one half
    assign sh = (exp < 13'sd0) ? 6'd0 : exp[5:0] + 6'd1;   // 0..32 when not huge_mag
    assign t = {32'd0, sig} << sh;
    assign ipart = (tiny_mag || is_zero) ? 32'd0 : t[84:53];
    assign g = !tiny_mag && !is_zero && t[52];
    assign s = !is_zero && (tiny_mag ? 1'b1 : (|t[51:0]));

    fp_roundup u_up (.rm(rm), .sign(sign), .lsb(ipart[0]), .g(g), .s(s), .up(up));
    assign mag = {1'b0, ipart} + {32'd0, up};

    logic invalid, range_bad;
    always_comb begin
        if (is_unsigned) range_bad = sign ? (mag != 33'd0) : mag[32];
        else range_bad = sign ? (mag > 33'h0_8000_0000) : (mag > 33'h0_7fff_ffff);
    end
    assign invalid = is_nan || is_inf || (!is_zero && (huge_mag || range_bad));

    always_comb begin
        flags = 5'd0;
        if (invalid) begin
            flags[`FF_NV] = 1'b1;
            if (is_nan || !sign) result = is_unsigned ? 32'hffff_ffff : 32'h7fff_ffff;
            else result = is_unsigned ? 32'h0000_0000 : 32'h8000_0000;
        end else begin
            flags[`FF_NX] = g | s;
            result = sign ? -mag[31:0] : mag[31:0];
        end
    end

    logic unused;
    assign unused = &{1'b0, exp[12:6]};
endmodule
