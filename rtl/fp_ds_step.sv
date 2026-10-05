// One radix-2 step of the divide / square-root recurrence of fp_divsqrt.sv
// (combinational).  Divide: subtract the divisor d from the remainder, then
// shift the remainder left.  Square root: bring down the next two radicand
// bits (from the top of d), then subtract 4*root + 1.
module fp_ds_step (
    input  logic        is_sqrt,
    input  logic [59:0] rem,
    input  logic [55:0] q,
    input  logic [53:0] d,
    output logic [59:0] rem_o,
    output logic [55:0] q_o,
    output logic [53:0] d_o
);
    logic [59:0] x, y, keep;
    logic [60:0] t;
    logic        fits;

    assign x = is_sqrt ? {rem[57:0], d[53:52]} : rem;
    assign y = is_sqrt ? {2'b00, q, 2'b01} : {6'd0, d};
    assign t = {1'b0, x} - {1'b0, y};
    assign fits = !t[60];
    assign keep = fits ? t[59:0] : x;
    assign rem_o = is_sqrt ? keep : {keep[58:0], 1'b0};
    assign q_o = {q[54:0], fits};
    assign d_o = is_sqrt ? {d[51:0], 2'b00} : d;
endmodule
