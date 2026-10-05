// Iterative divide and square root on significands (multi-cycle).
//
// Both are digit recurrences that produce the result most significant bit
// first, and they share one subtractor chain: two radix-2 steps per clock.
//   divide : remainder - divisor;          keep it if not negative, quotient bit 1
//   sqrt   : remainder - (4*root + 1);     keep it if not negative, root bit 1
// A double takes 28 cycles of two bits (56 result bits: 53 + guard + round,
// plus one more because a quotient may start with a zero); a single takes 14.
// What is left in the remainder is the sticky bit.  Rounding is done by
// fp_round afterwards.
//
// Subnormal operands are normalised first, one bit position per cycle (up
// to 52 extra cycles; they are rare).  Zero, infinity and NaN operands never
// get here: fpu.sv answers those directly.
module fp_divsqrt (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,          // one cycle; operands valid
    input  logic        kill,
    input  logic        is_sqrt,
    input  logic        dbl,
    input  logic signed [12:0] a_exp,
    input  logic [52:0] a_sig,
    input  logic signed [12:0] b_exp,
    input  logic [52:0] b_sig,
    output logic        done,           // one cycle: the outputs are valid
    output logic signed [12:0] exp,
    output logic [54:0] mant,
    output logic        sticky
);
    localparam logic [1:0] IDLE = 2'd0, PRE = 2'd1, RUN = 2'd2, FIN = 2'd3;
    logic [1:0]  state;
    logic        sqrt_q, dbl_q;
    logic signed [12:0] ea, eb, e_res;
    logic [52:0] sa, sb;
    logic [59:0] rem, rem1, rem2;
    logic [55:0] q, q1, q2;
    logic [53:0] d, d1, d2;       // divisor, or the radicand shifting out two bits per step
    logic [4:0]  count;
    logic        a_norm, b_norm;

    fp_ds_step u_step1 (.is_sqrt(sqrt_q), .rem(rem), .q(q), .d(d), .rem_o(rem1), .q_o(q1), .d_o(d1));
    fp_ds_step u_step2 (.is_sqrt(sqrt_q), .rem(rem1), .q(q1), .d(d1), .rem_o(rem2), .q_o(q2), .d_o(d2));

    assign a_norm = sa[52];
    assign b_norm = sqrt_q || sb[52];

    always_ff @(posedge clk) begin
        if (rst || kill) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: if (start) begin
                    sqrt_q <= is_sqrt;
                    dbl_q <= dbl;
                    ea <= a_exp;
                    eb <= b_exp;
                    sa <= a_sig;
                    sb <= b_sig;
                    state <= PRE;
                end
                PRE: begin
                    if (!a_norm) begin
                        sa <= {sa[51:0], 1'b0};
                        ea <= ea - 13'sd1;
                    end
                    if (!b_norm) begin
                        sb <= {sb[51:0], 1'b0};
                        eb <= eb - 13'sd1;
                    end
                    if (a_norm && b_norm) begin
                        q <= 56'd0;
                        count <= dbl_q ? 5'd27 : 5'd13;
                        if (sqrt_q) begin
                            // even exponent: radicand in [1,4), root exponent = half
                            // (an odd exponent gives one bit to the radicand: floor(ea / 2))
                            rem <= 60'd0;
                            d <= ea[0] ? {sa, 1'b0} : {1'b0, sa};
                            e_res <= {ea[12], ea[12:1]};
                        end else begin
                            rem <= {7'd0, sa};
                            d <= {1'b0, sb};
                            e_res <= ea - eb;
                        end
                        state <= RUN;
                    end
                end
                RUN: begin
                    rem <= rem2;
                    q <= q2;
                    d <= d2;
                    count <= count - 5'd1;
                    if (count == 5'd0) state <= FIN;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // result bits left-aligned to 56; a quotient below one has its leading bit one place down
    logic [55:0] x;
    assign x = dbl_q ? q : {q[27:0], 28'd0};
    assign done = (state == FIN);
    assign mant = x[55] ? x[55:1] : x[54:0];
    assign sticky = (rem != 60'd0) || (x[55] && x[0]);
    assign exp = x[55] ? e_res : e_res - 13'sd1;
endmodule
