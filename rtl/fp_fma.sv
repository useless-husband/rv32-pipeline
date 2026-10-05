// Fused multiply-add datapath: (a * b) +/- c on 53-bit significands with a
// single rounding at the end (done by fp_round).  FADD, FSUB, FMUL and the
// conversions to floating point use it too (b = 1, c = 0, or a = 0).
//
// The classic one-shifter arrangement (as in FPnew's fma and most textbook
// FMAs): the 106-bit product sits at a fixed place in a 163-bit window and
// only the addend moves.
//
//   bit 162 ........ 110 109 108 107 ................. 2  1 0
//       [ addend, shamt = 0 ] [ gap ] [    product      ] [0 0]
//
// shamt = 0 puts the addend at the top; larger shamt moves it right, past
// the product if need be, and what falls off the bottom becomes a sticky
// bit.  When the addend is so much larger that it would sit above the
// window it stays at the top instead: the product is then at least two bits
// below the addend's last place and only ever acts as a sticky bit, which
// it still does from where it is.
//
// Three registered steps, each short enough for the core's clock:
//   1. four 53 x 17-bit partial products (DSP blocks) | align the addend
//   2. carry-save reduction of the five terms, then one wide addition
//      (carry-select, in two halves); a negative difference is taken back
//      to a magnitude without a second carry chain
//   3. find the leading one and shift it to the top (combinational here,
//      registered by fpu.sv)
module fp_fma (
    input  logic         clk,
    input  logic         en_mul,
    input  logic         en_add,
    input  logic [52:0]  a_sig,
    input  logic [52:0]  b_sig,
    input  logic [52:0]  c_sig,
    input  logic [7:0]   shamt,          // 0..163
    input  logic         eff_sub,        // product and addend have opposite signs
    input  logic signed [12:0] exp_top,  // exponent of sum bit 163
    output logic         neg,            // after step 2: the addend was the larger one
    output logic         zero,           // after step 2: the sum is exactly zero
    output logic signed [12:0] exp,      // step 3: exponent of mant[54]
    output logic [54:0]  mant,
    output logic         sticky
);
    // ------------------------------------------------------------- step 1
    logic [69:0]  pp0, pp1, pp2;
    logic [54:0]  pp3;
    logic [162:0] aw;
    logic         aw_st;
    logic [215:0] sh_out;

    assign sh_out = {c_sig, 163'd0} >> shamt;

    always_ff @(posedge clk) begin
        if (en_mul) begin
            pp0 <= {17'd0, a_sig} * {53'd0, b_sig[16:0]};
            pp1 <= {17'd0, a_sig} * {53'd0, b_sig[33:17]};
            pp2 <= {17'd0, a_sig} * {53'd0, b_sig[50:34]};
            pp3 <= {2'd0, a_sig} * {53'd0, b_sig[52:51]};
            aw <= sh_out[215:53];
            aw_st <= (|sh_out[52:0]);
        end
    end

    // ------------------------------------------------------------- step 2
    // 165-bit two's complement: the product terms (shifted left by 2) and the
    // addend, inverted for an effective subtraction (that is -addend - 1).
    logic [164:0] x0, x1, x2, x3, x4, s1, c1, s2, c2, s3, c3, m1, m2, m3;

    assign x0 = {93'd0, pp0, 2'd0};
    assign x1 = {76'd0, pp1, 19'd0};
    assign x2 = {59'd0, pp2, 36'd0};
    assign x3 = {57'd0, pp3, 53'd0};
    assign x4 = eff_sub ? ~{2'b00, aw} : {2'b00, aw};

    // three levels of 3:2 carry-save adders
    assign s1 = x0 ^ x1 ^ x2;
    assign m1 = (x0 & x1) | (x0 & x2) | (x1 & x2);
    assign c1 = {m1[163:0], 1'b0};
    assign s2 = s1 ^ c1 ^ x3;
    assign m2 = (s1 & c1) | (s1 & x3) | (c1 & x3);
    assign c2 = {m2[163:0], 1'b0};
    assign s3 = s2 ^ c2 ^ x4;
    assign m3 = (s2 & c2) | (s2 & x4) | (c2 & x4);
    assign c3 = {m3[163:0], 1'b0};

    // r0 = s3 + c3 and r1 = s3 + c3 + 1, each half added for both carries
    logic [83:0]  lo0, lo1;
    logic [81:0]  hi0, hi1;
    logic [164:0] r0, r1, pos;
    logic         neg_c;

    assign lo0 = {1'b0, s3[82:0]} + {1'b0, c3[82:0]};
    assign lo1 = {1'b0, s3[82:0]} + {1'b0, c3[82:0]} + 84'd1;
    assign hi0 = s3[164:83] + c3[164:83];
    assign hi1 = s3[164:83] + c3[164:83] + 82'd1;
    assign r0 = {lo0[83] ? hi1 : hi0, lo0[82:0]};
    assign r1 = {lo1[83] ? hi1 : hi0, lo1[82:0]};

    // Subtraction: with P the product and A the addend's kept bits,
    //   r0 = P - A - 1 and r1 = P - A.
    // If addend bits fell off the bottom the true difference lies between the
    // two, so its integer part is r0 (and the sticky bit stays set).  If the
    // chosen value is negative the magnitude is A - P = ~r0 in both cases.
    assign pos = (eff_sub && !aw_st) ? r1 : r0;
    assign neg_c = eff_sub && pos[164];

    logic [163:0] sum;
    logic         sum_st;

    always_ff @(posedge clk) begin
        if (en_add) begin
            sum <= neg_c ? ~r0[163:0] : pos[163:0];
            sum_st <= aw_st;
            neg <= neg_c;
        end
    end

    // ------------------------------------------------------------- step 3
    // Normalise: find the leading one and shift it to the top, two bits of the
    // shift distance per level (0/64/128, then 0/16/32/48, 0/4/8/12, 0/1/2/3).
    // Each level looks at chunks of what the level above produced, so the
    // zero tests of a level run side by side.
    logic [163:0] na, nb, nc, n;
    logic [7:0]   lz;

    always_comb begin
        // level 1: 64-bit chunks
        if (sum[163:100] != 64'd0)      begin lz[7:6] = 2'd0; na = sum; end
        else if (sum[99:36] != 64'd0)   begin lz[7:6] = 2'd1; na = {sum[99:0], 64'd0}; end
        else                            begin lz[7:6] = 2'd2; na = {sum[35:0], 128'd0}; end
        // level 2: 16-bit chunks of the top 64 bits
        if (na[163:148] != 16'd0)       begin lz[5:4] = 2'd0; nb = na; end
        else if (na[147:132] != 16'd0)  begin lz[5:4] = 2'd1; nb = {na[147:0], 16'd0}; end
        else if (na[131:116] != 16'd0)  begin lz[5:4] = 2'd2; nb = {na[131:0], 32'd0}; end
        else                            begin lz[5:4] = 2'd3; nb = {na[115:0], 48'd0}; end
        // level 3: 4-bit chunks of the top 16 bits
        if (nb[163:160] != 4'd0)        begin lz[3:2] = 2'd0; nc = nb; end
        else if (nb[159:156] != 4'd0)   begin lz[3:2] = 2'd1; nc = {nb[159:0], 4'd0}; end
        else if (nb[155:152] != 4'd0)   begin lz[3:2] = 2'd2; nc = {nb[155:0], 8'd0}; end
        else                            begin lz[3:2] = 2'd3; nc = {nb[151:0], 12'd0}; end
        // level 4: the top 4 bits
        if (nc[163])                    begin lz[1:0] = 2'd0; n = nc; end
        else if (nc[162])               begin lz[1:0] = 2'd1; n = {nc[162:0], 1'd0}; end
        else if (nc[161])               begin lz[1:0] = 2'd2; n = {nc[161:0], 2'd0}; end
        else                            begin lz[1:0] = 2'd3; n = {nc[160:0], 3'd0}; end
    end

    assign mant = n[163:109];
    assign sticky = sum_st | (|n[108:0]);
    assign exp = exp_top - $signed({5'd0, lz});
    assign zero = (sum == 164'd0) && !sum_st;

    logic unused;
    assign unused = &{1'b0, m1[164], m2[164], m3[164], r1[164]};
endmodule
