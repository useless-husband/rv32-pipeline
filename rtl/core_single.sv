// Core A: single-cycle RV32IM reference core.
//
// Every instruction is fetched, decoded, executed and written back in one
// clock cycle, so CPI is exactly 1 and the clock period has to cover the
// whole path (instruction memory, decode, register read, ALU or the
// combinational multiplier/divider, data memory, write back).  Memories are
// outside the core with combinational reads ("magic memory", as in the
// 6.1910 single-cycle lab); writes happen at the clock edge.
`include "rv_defs.svh"

module core_single (
    input  logic        clk,
    input  logic        rst,
    // instruction memory (combinational read)
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    // data memory (combinational read of the addressed word, write at the edge)
    output logic [31:0] dmem_addr,     // word aligned
    output logic        dmem_re,
    input  logic [31:0] dmem_rdata,
    output logic [3:0]  dmem_wmask,    // nonzero = write these byte lanes
    output logic [31:0] dmem_wdata,
    // commit port (one record per instruction; see sim/sim_main.cpp)
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic        commit_trap,
    output logic [31:0] commit_cause,
    output logic        commit_rd_we,
    output logic [4:0]  commit_rd,
    output logic [31:0] commit_rd_val,
    output logic        commit_mem_we,
    output logic [31:0] commit_mem_addr,
    output logic [31:0] commit_mem_wdata,
    output logic [3:0]  commit_mem_wmask,
    output logic [`NUM_EVENTS-1:0] perf_events
);
    logic [31:0] pc, insn;

    // ---------------------------------------------------------------- decode
    logic [3:0]  alu_op;
    logic [1:0]  a_sel;
    logic        b_imm;
    logic [31:0] imm;
    logic [4:0]  rd, rs1, rs2;
    logic        uses_rs1, uses_rs2, rd_we;
    logic [2:0]  wb_sel, funct3;
    logic        is_branch, is_jal, is_jalr, is_load, is_store, is_mdu, is_div, is_csr, csr_writes;
    logic        is_ecall, is_ebreak, is_mret, is_fencei, dec_illegal;

    assign insn = imem_rdata;
    assign imem_addr = pc;

    logic [21:0] fp_unused;

    decoder u_dec (
        .insn(insn), .alu_op(alu_op), .a_sel(a_sel), .b_imm(b_imm), .imm(imm),
        .rd(rd), .rs1(rs1), .rs2(rs2), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2), .rd_we(rd_we),
        .wb_sel(wb_sel), .funct3(funct3), .is_branch(is_branch), .is_jal(is_jal), .is_jalr(is_jalr),
        .is_load(is_load), .is_store(is_store), .is_mdu(is_mdu), .is_div(is_div), .is_csr(is_csr),
        .csr_writes(csr_writes), .is_ecall(is_ecall), .is_ebreak(is_ebreak), .is_mret(is_mret),
        .is_fencei(is_fencei), .illegal(dec_illegal),
        // F and D exist on core B only (the decoder's FPU parameter stays 0 here)
        .rs3(fp_unused[4:0]), .is_fp(fp_unused[5]), .fp_unit(fp_unused[6]), .fp_op(fp_unused[11:7]),
        .fp_dbl(fp_unused[12]), .fp_rm_dyn(fp_unused[13]), .uses_frs1(fp_unused[14]),
        .uses_frs2(fp_unused[15]), .uses_frs3(fp_unused[16]), .frd_we(fp_unused[17]));

    // -------------------------------------------------------------- register
    logic [31:0] x1, x2, wb_val;
    logic        wb_en;

    regfile #(.BYPASS(1'b0)) u_rf (
        .clk(clk), .ra1(rs1), .ra2(rs2), .rd1(x1), .rd2(x2), .we(wb_en), .wa(rd), .wd(wb_val));

    // --------------------------------------------------------------- execute
    logic [31:0] alu_a, alu_b, alu_y, mdu_y, pc4, br_target, next_pc, target;
    logic        taken, jumps;

    assign alu_a = (a_sel == `A_PC) ? pc : (a_sel == `A_ZERO) ? 32'd0 : x1;
    assign alu_b = b_imm ? imm : x2;
    alu u_alu (.op(alu_op), .a(alu_a), .b(alu_b), .y(alu_y));
    muldiv_comb u_mdu (.op(funct3), .a(x1), .b(x2), .y(mdu_y));

    always_comb begin
        case (funct3)
            3'b000: taken = (x1 == x2);
            3'b001: taken = (x1 != x2);
            3'b100: taken = ($signed(x1) < $signed(x2));
            3'b101: taken = ($signed(x1) >= $signed(x2));
            3'b110: taken = (x1 < x2);
            default: taken = (x1 >= x2);
        endcase
    end

    assign pc4 = pc + 32'd4;
    assign br_target = pc + imm;
    assign jumps = is_jal || is_jalr || (is_branch && taken);
    assign target = is_jalr ? {alu_y[31:1], 1'b0} : br_target;

    // ------------------------------------------------------------ memory
    logic [31:0] st_data, ld_data;
    logic [3:0]  st_mask;
    logic        mem_misaligned;

    lsu_align u_lsu (
        .funct3(funct3), .offset(alu_y[1:0]), .store_data(x2), .wdata(st_data), .wmask(st_mask),
        .rdata(dmem_rdata), .load_data(ld_data), .misaligned(mem_misaligned));

    // ------------------------------------------------------------ CSRs, traps
    logic [31:0] csr_rdata, mtvec, mepc, csr_src;
    logic        csr_illegal, writes_instret;
    logic        exc;
    logic [31:0] exc_cause, exc_tval;

    always_comb begin
        exc = 1'b1;
        exc_cause = `CAUSE_ILLEGAL;
        exc_tval = insn;
        if (dec_illegal || (is_csr && csr_illegal)) begin
            exc_cause = `CAUSE_ILLEGAL;
            exc_tval = insn;
        end else if (is_ecall) begin
            exc_cause = `CAUSE_ECALL_M;
            exc_tval = 32'd0;
        end else if (is_ebreak) begin
            exc_cause = `CAUSE_BREAKPOINT;
            exc_tval = 32'd0;
        end else if (jumps && target[1]) begin
            exc_cause = `CAUSE_MISALIGNED_FETCH;
            exc_tval = target;
        end else if (is_load && mem_misaligned) begin
            exc_cause = `CAUSE_MISALIGNED_LOAD;
            exc_tval = alu_y;
        end else if (is_store && mem_misaligned) begin
            exc_cause = `CAUSE_MISALIGNED_STORE;
            exc_tval = alu_y;
        end else begin
            exc = 1'b0;
        end
    end

    assign csr_src = funct3[2] ? {27'd0, rs1} : x1;

    csr_file u_csr (
        .clk(clk), .rst(rst), .addr(insn[31:20]), .op(funct3[1:0]), .src(csr_src),
        .writes(csr_writes), .we(is_csr && !exc && !rst), .rdata(csr_rdata), .illegal(csr_illegal),
        .writes_instret(writes_instret),
        .trap(exc && !rst), .trap_pc(pc), .trap_cause(exc_cause), .trap_tval(exc_tval),
        .mret(is_mret && !rst), .mtvec(mtvec), .mepc(mepc),
        .instret_inc(!exc && !rst && !writes_instret), .events(perf_events),
        .fp_flags(5'd0), .fp_flags_we(1'b0), .fp_dirty(1'b0), .frm(fp_unused[20:18]), .fs_off(fp_unused[21]));

    // ------------------------------------------------------------- write back
    always_comb begin
        case (wb_sel)
            `WB_MEM: wb_val = ld_data;
            `WB_PC4: wb_val = pc4;
            `WB_CSR: wb_val = csr_rdata;
            `WB_MDU: wb_val = mdu_y;
            default: wb_val = alu_y;
        endcase
    end
    assign wb_en = rd_we && !exc && !rst;

    assign next_pc = exc ? mtvec : is_mret ? mepc : jumps ? target : pc4;

    always_ff @(posedge clk)
        if (rst) pc <= `RESET_PC;
        else pc <= next_pc;

    assign dmem_addr = {alu_y[31:2], 2'b00};
    assign dmem_re = is_load && !exc;
    assign dmem_wmask = (is_store && !exc && !rst) ? st_mask : 4'b0000;
    assign dmem_wdata = st_data;

    // ------------------------------------------------------------ commit port
    assign commit_valid = !rst;
    assign commit_pc = pc;
    assign commit_insn = insn;
    assign commit_trap = exc;
    assign commit_cause = exc_cause;
    assign commit_rd_we = wb_en;
    assign commit_rd = rd;
    assign commit_rd_val = wb_val;
    assign commit_mem_we = dmem_wmask != 4'b0000;
    assign commit_mem_addr = dmem_addr;
    assign commit_mem_wdata = st_data;
    assign commit_mem_wmask = dmem_wmask;

    // Branch and jump counts are architectural, so they exist here too; the
    // single-cycle core has no predictor and no caches.
    always_comb begin
        perf_events = '0;
        perf_events[`EV_BRANCH] = is_branch && !exc && !rst;
        perf_events[`EV_JUMP] = (is_jal || is_jalr) && !exc && !rst;
    end

    // unused decode outputs in this core
    logic unused;
    assign unused = &{1'b0, uses_rs1, uses_rs2, is_div, is_mdu, is_fencei, imm[0], fp_unused};
endmodule
