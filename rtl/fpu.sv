// Floating-point unit for RV32F and RV32D (IEEE 754-2019 binary32 and
// binary64, all five rounding modes, exact exception flags).
//
// The pipeline treats it like the iterative divider: the instruction waits
// in EX until `done`.  How long depends on the operation:
//
//   1 cycle   sign injection, FMIN/FMAX, comparisons, FCLASS, FMV (fp_misc,
//             combinational from the operands)
//   2 cycles  FCVT.W/WU (fp_f2i), and any result that needs no arithmetic
//             (a NaN, an infinity, a zero divisor, ...)
//   5 cycles  FADD, FSUB, FMUL, FMADD/FMSUB/FNMSUB/FNMADD, FCVT.S.D,
//             FCVT.D.S, FCVT.fmt.W/WU: unpack | partial products and
//             alignment | add | normalise | round (fp_fma, fp_round)
//   18 / 32   FDIV and FSQRT, single / double (fp_divsqrt), plus one cycle
//             per bit of normalisation for a subnormal operand
//
// One datapath serves both formats: a single is unpacked into the top of
// the 53-bit significand and only the rounder (and the divide/sqrt
// iteration count) looks at the format.
//
// Protocol: `start` is high while a multi-cycle FP operation sits in EX with
// its operands; the unit latches them in its first cycle.  `done` stays
// high with stable outputs until `ack` (the instruction leaves EX).  `kill`
// abandons the operation.
`include "rv_defs.svh"

module fpu (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        kill,
    input  logic        ack,
    input  logic [4:0]  op,         // FOP_*
    input  logic        dbl,        // format of the result (and of the operands, except FOP_F2F)
    input  logic [2:0]  rm,         // rounding mode, already resolved (0..4)
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [63:0] c,
    input  logic [31:0] ia,         // integer operand (FCVT.fmt.W/WU, FMV.W.X)
    output logic        done,
    output logic [63:0] result,     // floating-point result (singles NaN-boxed)
    output logic [31:0] iresult,    // integer result
    output logic [4:0]  flags
);
    localparam logic [2:0] S_IDLE = 3'd0, S_MUL = 3'd1, S_ADD = 3'd2, S_NORM = 3'd3, S_ROUND = 3'd4,
                           S_DS = 3'd5, S_F2I = 3'd6, S_SPEC = 3'd7;
    logic [2:0] state;
    logic       is_comb;
    assign is_comb = (op >= `FOP_SGNJ);

    // ------------------------------------------------------------ unpack
    logic        ua_s, ub_s, uc_s;
    logic signed [12:0] ua_e, ub_e, uc_e;
    logic [52:0] ua_m, ub_m, uc_m;
    logic        ua_zero, ua_inf, ua_nan, ua_snan, ub_zero, ub_inf, ub_nan, ub_snan;
    logic        uc_zero, uc_inf, uc_nan, uc_snan;

    // FCVT.S.D / FCVT.D.S read the other format
    fp_unpack u_ua (.x(a), .dbl((op == `FOP_F2F) ? !dbl : dbl), .sign(ua_s), .exp(ua_e), .sig(ua_m),
                    .is_zero(ua_zero), .is_inf(ua_inf), .is_nan(ua_nan), .is_snan(ua_snan));
    fp_unpack u_ub (.x(b), .dbl(dbl), .sign(ub_s), .exp(ub_e), .sig(ub_m),
                    .is_zero(ub_zero), .is_inf(ub_inf), .is_nan(ub_nan), .is_snan(ub_snan));
    fp_unpack u_uc (.x(c), .dbl(dbl), .sign(uc_s), .exp(uc_e), .sig(uc_m),
                    .is_zero(uc_zero), .is_inf(uc_inf), .is_nan(uc_nan), .is_snan(uc_snan));

    // ------------------------------------------- one-cycle operations
    logic [63:0] misc_result;
    logic [31:0] misc_iresult;
    logic [4:0]  misc_flags;

    fp_misc u_misc (
        .op(op), .dbl(dbl), .a(a), .b(b), .ia(ia),
        .a_zero(ua_zero), .a_inf(ua_inf), .a_nan(ua_nan), .a_snan(ua_snan),
        .a_subnormal(!ua_m[52] && !ua_zero),
        .b_zero(ub_zero), .b_nan(ub_nan), .b_snan(ub_snan),
        .result(misc_result), .iresult(misc_iresult), .flags(misc_flags));

    // ---------------------------------------------- operand selection
    // Every arithmetic operation is brought to the form  P * Q + R:
    //   FADD/FSUB   a * 1 + (+/-)b        FMUL    a * b + 0
    //   FMADD etc.  (+/-)(a * b) + (+/-)c
    //   conversions 0 * 1 + (the value to be rounded into the new format)
    logic        p_s, r_s;                  // signs of the product and of the addend
    logic signed [12:0] p_e, q_e, r_e;
    logic [52:0] p_m, q_m, r_m;
    logic        p_zero, p_inf, p_nan, p_snan, q_zero, q_inf, q_nan, q_snan, r_zero, r_inf, r_nan, r_snan;
    logic [31:0] imag;
    logic        ineg;

    assign ineg = (op == `FOP_I2F) && ia[31];
    assign imag = ineg ? -ia : ia;

    always_comb begin
        // defaults: FMADD
        p_e = ua_e; p_m = ua_m; p_zero = ua_zero; p_inf = ua_inf; p_nan = ua_nan; p_snan = ua_snan;
        q_e = ub_e; q_m = ub_m; q_zero = ub_zero; q_inf = ub_inf; q_nan = ub_nan; q_snan = ub_snan;
        r_e = uc_e; r_m = uc_m; r_zero = uc_zero; r_inf = uc_inf; r_nan = uc_nan; r_snan = uc_snan;
        p_s = ua_s ^ ub_s ^ (op == `FOP_NMSUB || op == `FOP_NMADD);
        r_s = uc_s ^ (op == `FOP_MSUB || op == `FOP_NMADD);
        case (op)
            `FOP_ADD, `FOP_SUB: begin
                q_e = 13'sd0; q_m = {1'b1, 52'd0}; q_zero = 1'b0; q_inf = 1'b0; q_nan = 1'b0; q_snan = 1'b0;
                r_e = ub_e; r_m = ub_m; r_zero = ub_zero; r_inf = ub_inf; r_nan = ub_nan; r_snan = ub_snan;
                p_s = ua_s;
                r_s = ub_s ^ (op == `FOP_SUB);
            end
            `FOP_MUL: begin
                // adding a zero of the product's sign leaves the product (and its sign) alone
                r_e = 13'sd0; r_m = 53'd0; r_zero = 1'b1; r_inf = 1'b0; r_nan = 1'b0; r_snan = 1'b0;
                p_s = ua_s ^ ub_s;
                r_s = ua_s ^ ub_s;
            end
            `FOP_F2F: begin
                p_e = 13'sd0; p_m = 53'd0; p_zero = 1'b1; p_inf = 1'b0; p_nan = 1'b0; p_snan = 1'b0;
                q_e = 13'sd0; q_m = {1'b1, 52'd0}; q_zero = 1'b0; q_inf = 1'b0; q_nan = 1'b0; q_snan = 1'b0;
                r_e = ua_e; r_m = ua_m; r_zero = ua_zero; r_inf = ua_inf; r_nan = ua_nan; r_snan = ua_snan;
                p_s = ua_s;
                r_s = ua_s;
            end
            `FOP_I2F, `FOP_IU2F: begin
                // the integer as an unnormalised number: imag * 2^0 = (imag << 21) * 2^(31 - 52)
                p_e = 13'sd0; p_m = 53'd0; p_zero = 1'b1; p_inf = 1'b0; p_nan = 1'b0; p_snan = 1'b0;
                q_e = 13'sd0; q_m = {1'b1, 52'd0}; q_zero = 1'b0; q_inf = 1'b0; q_nan = 1'b0; q_snan = 1'b0;
                r_e = 13'sd31; r_m = {imag, 21'd0}; r_zero = (ia == 32'd0); r_inf = 1'b0; r_nan = 1'b0; r_snan = 1'b0;
                p_s = ineg;
                r_s = ineg;
            end
            default: ;
        endcase
    end

    // Where the addend goes in the adder window (see fp_fma.sv).  d is how far
    // the addend's exponent is above the product's.
    logic signed [12:0] e_prod, d_exp, sh_want, exp_top_c;
    logic               pz, anchor_prod;
    logic [7:0]         shamt_c;

    assign pz = p_zero || q_zero;
    assign e_prod = p_e + q_e;
    assign d_exp = r_e - e_prod;
    assign anchor_prod = !pz && (r_zero || d_exp <= 13'sd56);
    assign sh_want = 13'sd56 - d_exp;
    assign shamt_c = (!anchor_prod || r_zero) ? 8'd0 : (sh_want > 13'sd163) ? 8'd163 : sh_want[7:0];
    assign exp_top_c = anchor_prod ? e_prod + 13'sd57 : r_e + 13'sd1;

    // ------------------------------------- results that need no arithmetic
    logic        spec, spec_nv, spec_dz, spec_nan, spec_inf, spec_zero, spec_s;
    logic        inf_x_zero, prod_inf, any_nan, any_snan;

    assign inf_x_zero = (p_inf && q_zero) || (p_zero && q_inf);
    assign prod_inf = (p_inf || q_inf) && !inf_x_zero;
    assign any_nan = p_nan || q_nan || r_nan;
    assign any_snan = p_snan || q_snan || r_snan;

    always_comb begin
        spec = 1'b0;
        spec_nv = 1'b0;
        spec_dz = 1'b0;
        spec_nan = 1'b0;
        spec_inf = 1'b0;
        spec_zero = 1'b0;
        spec_s = 1'b0;
        case (op)
            `FOP_DIV: begin
                spec_s = ua_s ^ ub_s;
                if (ua_nan || ub_nan || (ua_inf && ub_inf) || (ua_zero && ub_zero)) begin
                    spec = 1'b1; spec_nan = 1'b1;
                    spec_nv = ua_snan || ub_snan || (ua_inf && ub_inf) || (ua_zero && ub_zero);
                end else if (ua_inf) begin
                    spec = 1'b1; spec_inf = 1'b1;
                end else if (ub_inf || ua_zero) begin
                    spec = 1'b1; spec_zero = 1'b1;
                end else if (ub_zero) begin
                    spec = 1'b1; spec_inf = 1'b1; spec_dz = 1'b1;
                end
            end
            `FOP_SQRT: begin
                spec_s = ua_s;
                if (ua_nan) begin
                    spec = 1'b1; spec_nan = 1'b1; spec_nv = ua_snan;
                end else if (ua_zero) begin
                    spec = 1'b1; spec_zero = 1'b1;
                end else if (ua_s) begin
                    spec = 1'b1; spec_nan = 1'b1; spec_nv = 1'b1;
                end else if (ua_inf) begin
                    spec = 1'b1; spec_inf = 1'b1;
                end
            end
            `FOP_F2I, `FOP_F2IU: ;
            default: begin // the multiply-add family
                // inf * 0 is invalid even if the addend is a quiet NaN
                spec_nv = any_snan || inf_x_zero || (!any_nan && prod_inf && r_inf && (p_s != r_s));
                if (any_nan || spec_nv) begin
                    spec = 1'b1; spec_nan = 1'b1;
                end else if (prod_inf) begin
                    spec = 1'b1; spec_inf = 1'b1; spec_s = p_s;
                end else if (r_inf) begin
                    spec = 1'b1; spec_inf = 1'b1; spec_s = r_s;
                end
            end
        endcase
    end

    // -------------------------------------------------- operand registers
    logic [4:0]  op_q;
    logic        dbl_q, sp_q, sr_q, a_zero_q, a_inf_q, a_nan_q;
    logic [2:0]  rm_q;
    logic signed [12:0] pe_q, qe_q, exp_top_q;
    logic [52:0] pm_q, qm_q, rm_sig_q;
    logic [7:0]  shamt_q;
    logic [63:0] spec_res_q;
    logic [4:0]  spec_flags_q;

    // the rounder's inputs
    logic        rnd_s;
    logic signed [12:0] rnd_e;
    logic [54:0] rnd_m;
    logic        rnd_st, rnd_below, pre_below;
    logic [5:0]  rnd_sh, pre_sh;

    logic        ds_start, ds_done, ds_sticky, fma_neg, fma_zero, fma_sticky;
    logic signed [12:0] ds_exp, fma_exp;
    logic [54:0] ds_mant, fma_mant;
    logic        is_ds_op;

    assign is_ds_op = (op == `FOP_DIV || op == `FOP_SQRT);
    assign ds_start = (state == S_IDLE) && start && !is_comb && is_ds_op && !spec;

    always_ff @(posedge clk) begin
        if (rst || kill) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (start && !is_comb) begin
                    op_q <= op;
                    dbl_q <= dbl;
                    rm_q <= rm;
                    // divide, square root and FCVT.W use operands a and b as they are
                    if (is_ds_op || op == `FOP_F2I || op == `FOP_F2IU) begin
                        sp_q <= (op == `FOP_DIV) ? ua_s ^ ub_s : ua_s;
                        pe_q <= ua_e;
                        pm_q <= ua_m;
                        qe_q <= ub_e;
                        qm_q <= ub_m;
                    end else begin
                        sp_q <= p_s;
                        pe_q <= p_e;
                        pm_q <= pz ? 53'd0 : p_m;
                        qe_q <= q_e;
                        qm_q <= q_m;
                    end
                    sr_q <= r_s;
                    rm_sig_q <= r_m;
                    shamt_q <= shamt_c;
                    exp_top_q <= exp_top_c;
                    a_zero_q <= ua_zero;
                    a_inf_q <= ua_inf;
                    a_nan_q <= ua_nan;
                    spec_flags_q <= {spec_nv, spec_dz, 3'b000};
                    if (spec_nan) spec_res_q <= dbl ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
                    else if (dbl) spec_res_q <= {spec_s, {11{spec_inf}}, 52'd0};
                    else spec_res_q <= {32'hffff_ffff, spec_s, {8{spec_inf}}, 23'd0};
                    if (spec) state <= S_SPEC;
                    else if (is_ds_op) state <= S_DS;
                    else if (op == `FOP_F2I || op == `FOP_F2IU) state <= S_F2I;
                    else state <= S_MUL;
                end
                S_MUL: state <= S_ADD;
                S_ADD: state <= S_NORM;
                S_NORM: begin
                    // an exact zero is +0, or -0 when rounding down; equal signs keep their sign
                    if (fma_zero) rnd_s <= (sp_q != sr_q) ? (rm_q == `RM_RDN) : sp_q;
                    else rnd_s <= fma_neg ? sr_q : sp_q;
                    rnd_e <= fma_exp;
                    rnd_m <= fma_mant;
                    rnd_st <= fma_sticky;
                    rnd_below <= pre_below;
                    rnd_sh <= pre_sh;
                    state <= S_ROUND;
                end
                S_DS: if (ds_done) begin
                    rnd_s <= sp_q;
                    rnd_e <= ds_exp;
                    rnd_m <= ds_mant;
                    rnd_st <= ds_sticky;
                    rnd_below <= pre_below;
                    rnd_sh <= pre_sh;
                    state <= S_ROUND;
                end
                default: if (ack) state <= S_IDLE;   // S_ROUND, S_F2I, S_SPEC: wait to be read
            endcase
        end
    end

    // ---------------------------------------------------------- datapaths
    fp_fma u_fma (
        .clk(clk), .en_mul(state == S_MUL), .en_add(state == S_ADD),
        .a_sig(pm_q), .b_sig(qm_q), .c_sig(rm_sig_q), .shamt(shamt_q), .eff_sub(sp_q != sr_q),
        .exp_top(exp_top_q), .neg(fma_neg), .zero(fma_zero), .exp(fma_exp), .mant(fma_mant),
        .sticky(fma_sticky));

    fp_divsqrt u_ds (
        .clk(clk), .rst(rst), .start(ds_start), .kill(kill), .is_sqrt(op == `FOP_SQRT), .dbl(dbl),
        .a_exp(ua_e), .a_sig(ua_m), .b_exp(ub_e), .b_sig(ub_m),
        .done(ds_done), .exp(ds_exp), .mant(ds_mant), .sticky(ds_sticky));

    logic [63:0] rnd_result;
    logic [4:0]  rnd_flags, f2i_flags;
    logic [31:0] f2i_result;

    // the subnormal shift distance is worked out as the rounder's inputs are registered
    fp_denorm u_pre (.dbl(dbl_q), .exp((state == S_DS) ? ds_exp : fma_exp), .below(pre_below), .sh(pre_sh));

    fp_round u_round (
        .dbl(dbl_q), .rm(rm_q), .sign(rnd_s), .exp(rnd_e), .mant(rnd_m), .sticky(rnd_st),
        .below(rnd_below), .sh(rnd_sh),
        .result(rnd_result), .flags(rnd_flags));

    fp_f2i u_f2i (
        .is_unsigned(op_q == `FOP_F2IU), .rm(rm_q), .sign(sp_q), .exp(pe_q), .sig(pm_q),
        .is_zero(a_zero_q), .is_inf(a_inf_q), .is_nan(a_nan_q), .result(f2i_result), .flags(f2i_flags));

    // ------------------------------------------------------------ outputs
    always_comb begin
        done = 1'b0;
        result = misc_result;
        iresult = misc_iresult;
        flags = misc_flags;
        case (state)
            S_IDLE: done = is_comb;
            S_ROUND: begin done = 1'b1; result = rnd_result; flags = rnd_flags; end
            S_F2I: begin done = 1'b1; iresult = f2i_result; flags = f2i_flags; end
            S_SPEC: begin done = 1'b1; result = spec_res_q; flags = spec_flags_q; end
            default: ;
        endcase
    end

    logic unused;
    assign unused = &{1'b0, qe_q, spec_zero};
endmodule
