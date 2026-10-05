// Round and pack: the one place where a result is rounded, checked for
// overflow and underflow and turned into a bit pattern (combinational).
//
// Input: sign, a normalised 55-bit significand (bit 54 is the leading one,
// or the whole thing is zero), the exponent of that leading bit and a
// sticky bit for everything below.  If the exponent is below emin the
// significand is first shifted right into the subnormal range (`below` and
// the distance `sh` come from fp_denorm, one register earlier).  Then the
// result is rounded at 24 bits (single) or 53 bits (double).
//
// Tininess is detected after rounding, as RISC-V requires: underflow is
// raised when the result is inexact and would still be below 2^emin if the
// exponent range were unbounded.
`include "rv_defs.svh"

module fp_round (
    input  logic        dbl,
    input  logic [2:0]  rm,
    input  logic        sign,
    input  logic signed [12:0] exp,
    input  logic [54:0] mant,
    input  logic        sticky,
    input  logic        below,          // exp < emin (fp_denorm)
    input  logic [5:0]  sh,             // emin - exp, saturated (fp_denorm)
    output logic [63:0] result,
    output logic [4:0]  flags
);
    logic signed [12:0] emin, emax, e_base, biased0, biased1, biased;
    logic [118:0] shifted;
    logic [54:0]  dm;
    logic         ds;

    assign emin = dbl ? -13'sd1022 : -13'sd126;
    assign emax = dbl ? 13'sd1023 : 13'sd127;
    assign shifted = {mant, 64'd0} >> sh;
    assign dm = shifted[118:64];
    assign ds = sticky | (|shifted[63:0]);

    // rounding position: bit 2 of dm for a double, bit 31 for a single
    logic        lsb, g, s, up, g_u, s_u, ones_u, up_u;
    logic [52:0] inc_in;
    logic [53:0] sum;

    always_comb begin
        if (dbl) begin
            lsb = dm[2];
            g = dm[1];
            s = dm[0] | ds;
            inc_in = dm[54:2];
            g_u = mant[1];
            s_u = mant[0] | sticky;
            ones_u = (&mant[54:2]);
        end else begin
            lsb = dm[31];
            g = dm[30];
            s = (|dm[29:0]) | ds;
            inc_in = {dm[54:31], 29'h1fff_ffff};   // ones below: the carry ripples to bit 29
            g_u = mant[30];
            s_u = (|mant[29:0]) | sticky;
            ones_u = (&mant[54:31]);
        end
    end

    fp_roundup u_up (.rm(rm), .sign(sign), .lsb(lsb), .g(g), .s(s), .up(up));
    // the same decision on the significand before the subnormal shift (for tininess)
    fp_roundup u_up_u (.rm(rm), .sign(sign), .lsb(1'b1), .g(g_u), .s(s_u), .up(up_u));

    assign sum = {1'b0, inc_in} + {53'd0, up};

    logic cout, hidden, overflow, inexact, tiny, to_max;
    assign cout = sum[53];                 // 1.11..1 rounded up to 10.0
    assign hidden = cout | sum[52];
    // exponent field for both outcomes of the rounding carry, chosen late
    assign e_base = below ? emin : exp;
    assign biased0 = e_base + (dbl ? 13'sd1023 : 13'sd127);
    assign biased1 = e_base + (dbl ? 13'sd1024 : 13'sd128);
    assign biased = cout ? biased1 : biased0;
    assign overflow = hidden && !below && ((exp > emax) || (exp == emax && cout));
    assign inexact = g | s;
    assign tiny = below && !((exp == emin - 13'sd1) && ones_u && up_u);
    assign to_max = (rm == `RM_RTZ) || (rm == `RM_RDN && !sign) || (rm == `RM_RUP && sign);

    always_comb begin
        if (dbl) begin
            if (overflow) result = to_max ? {sign, 11'h7fe, {52{1'b1}}} : {sign, 11'h7ff, 52'd0};
            else result = {sign, hidden ? biased[10:0] : 11'd0, sum[51:0]};
        end else begin
            if (overflow) result = to_max ? {32'hffff_ffff, sign, 8'hfe, {23{1'b1}}} : {32'hffff_ffff, sign, 8'hff, 23'd0};
            else result = {32'hffff_ffff, sign, hidden ? biased[7:0] : 8'd0, sum[51:29]};
        end
        flags = 5'd0;
        flags[`FF_OF] = overflow;
        flags[`FF_UF] = tiny && inexact;
        flags[`FF_NX] = inexact || overflow;
    end

    logic unused;
    assign unused = &{1'b0, biased[12:11], sum[28:0]};
endmodule
