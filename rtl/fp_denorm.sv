// How far a result must be shifted right to become subnormal (combinational):
// `below` when its exponent is under emin of the format, `sh` = emin - exp,
// saturated at 63 (more than the significand's width, so everything becomes
// sticky).  Computed one step ahead of fp_round to keep the rounding step short.
module fp_denorm (
    input  logic        dbl,
    input  logic signed [12:0] exp,
    output logic        below,
    output logic [5:0]  sh
);
    logic signed [12:0] emin, sh_full;

    assign emin = dbl ? -13'sd1022 : -13'sd126;
    assign below = (exp < emin);
    assign sh_full = emin - exp;
    assign sh = !below ? 6'd0 : (sh_full > 13'sd63) ? 6'd63 : sh_full[5:0];
endmodule
