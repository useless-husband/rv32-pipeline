// Instruction decoder for RV32IM + Zicsr + Zifencei (machine mode), plus F
// and D when FPU = 1.  Purely combinational; shared by both cores.  An
// illegal encoding clears every side-effect output (no register write, no
// memory access) and sets `illegal`.  Whether a CSR number exists is decided
// by csr_file, not here.  Two F/D checks depend on CSR state and are made in
// EX instead: mstatus.FS must be on, and a dynamic rounding mode (funct3 =
// 111) needs a valid frm.
`include "rv_defs.svh"

module decoder #(
    parameter bit FPU = 1'b0
) (
    input  logic [31:0] insn,
    output logic [3:0]  alu_op,
    output logic [1:0]  a_sel,
    output logic        b_imm,      // ALU operand B: 1 = immediate, 0 = rs2
    output logic [31:0] imm,
    output logic [4:0]  rd,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic        uses_rs1,
    output logic        uses_rs2,
    output logic        rd_we,      // writes rd, and rd is not x0
    output logic [2:0]  wb_sel,
    output logic [2:0]  funct3,
    output logic        is_branch,
    output logic        is_jal,
    output logic        is_jalr,
    output logic        is_load,
    output logic        is_store,
    output logic        is_mdu,     // M extension
    output logic        is_div,     // DIV/DIVU/REM/REMU
    output logic        is_csr,
    output logic        csr_writes, // CSR instruction that writes its CSR
    output logic        is_ecall,
    output logic        is_ebreak,
    output logic        is_mret,
    output logic        is_fencei,
    output logic        illegal,
    // F and D (all zero when FPU = 0)
    output logic [4:0]  rs3,
    output logic        is_fp,      // any F/D instruction, including FLW/FLD/FSW/FSD
    output logic        fp_unit,    // executes in the FPU
    output logic [4:0]  fp_op,      // FOP_*
    output logic        fp_dbl,     // double format (for FLD/FSD: an 8-byte access)
    output logic        fp_rm_dyn,  // rounding mode comes from frm
    output logic        uses_frs1,
    output logic        uses_frs2,
    output logic        uses_frs3,
    output logic        frd_we      // writes floating-point register rd
);
    logic [6:0] opcode, funct7;
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    logic writes, legal;
    logic fwrites, fmt_ok, rm_ok, rm_used, fop_ok;
    logic [4:0] funct5;

    assign opcode = insn[6:0];
    assign funct3 = insn[14:12];
    assign funct7 = insn[31:25];
    assign rd     = insn[11:7];
    assign rs1    = insn[19:15];
    assign rs2    = insn[24:20];
    assign rs3    = insn[31:27];
    assign funct5 = insn[31:27];
    assign fmt_ok = (insn[26] == 1'b0);                       // S (00) or D (01)
    assign rm_ok  = (funct3 <= 3'b100) || (funct3 == 3'b111); // 101 and 110 are reserved

    assign imm_i = {{20{insn[31]}}, insn[31:20]};
    assign imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
    assign imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
    assign imm_u = {insn[31:12], 12'b0};
    assign imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

    always_comb begin
        alu_op = `ALU_ADD;
        a_sel = `A_RS1;
        b_imm = 1'b1;
        imm = imm_i;
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        writes = 1'b0;
        wb_sel = `WB_ALU;
        is_branch = 1'b0;
        is_jal = 1'b0;
        is_jalr = 1'b0;
        is_load = 1'b0;
        is_store = 1'b0;
        is_mdu = 1'b0;
        is_csr = 1'b0;
        is_ecall = 1'b0;
        is_ebreak = 1'b0;
        is_mret = 1'b0;
        is_fencei = 1'b0;
        legal = 1'b0;
        is_fp = 1'b0;
        fp_unit = 1'b0;
        fp_op = `FOP_ADD;
        fp_dbl = insn[25];
        fwrites = 1'b0;
        uses_frs1 = 1'b0;
        uses_frs2 = 1'b0;
        uses_frs3 = 1'b0;
        rm_used = 1'b0;
        fop_ok = 1'b0;

        case (opcode)
            7'b0110111: begin // LUI
                legal = 1'b1; writes = 1'b1; a_sel = `A_ZERO; imm = imm_u;
            end
            7'b0010111: begin // AUIPC
                legal = 1'b1; writes = 1'b1; a_sel = `A_PC; imm = imm_u;
            end
            7'b1101111: begin // JAL
                legal = 1'b1; writes = 1'b1; is_jal = 1'b1; imm = imm_j; wb_sel = `WB_PC4;
            end
            7'b1100111: begin // JALR
                legal = (funct3 == 3'b000);
                writes = 1'b1; is_jalr = 1'b1; uses_rs1 = 1'b1; wb_sel = `WB_PC4;
            end
            7'b1100011: begin // branches
                legal = (funct3 != 3'b010) && (funct3 != 3'b011);
                is_branch = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; imm = imm_b;
            end
            7'b0000011: begin // loads
                legal = (funct3 == 3'b000) || (funct3 == 3'b001) || (funct3 == 3'b010) ||
                        (funct3 == 3'b100) || (funct3 == 3'b101);
                writes = 1'b1; is_load = 1'b1; uses_rs1 = 1'b1; wb_sel = `WB_MEM;
            end
            7'b0100011: begin // stores
                legal = (funct3 == 3'b000) || (funct3 == 3'b001) || (funct3 == 3'b010);
                is_store = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; imm = imm_s;
            end
            7'b0010011: begin // OP-IMM
                writes = 1'b1; uses_rs1 = 1'b1;
                case (funct3)
                    3'b000: begin legal = 1'b1; alu_op = `ALU_ADD; end
                    3'b010: begin legal = 1'b1; alu_op = `ALU_SLT; end
                    3'b011: begin legal = 1'b1; alu_op = `ALU_SLTU; end
                    3'b100: begin legal = 1'b1; alu_op = `ALU_XOR; end
                    3'b110: begin legal = 1'b1; alu_op = `ALU_OR; end
                    3'b111: begin legal = 1'b1; alu_op = `ALU_AND; end
                    3'b001: begin legal = (funct7 == 7'b0000000); alu_op = `ALU_SLL; end
                    default: begin // 3'b101
                        legal = (funct7 == 7'b0000000) || (funct7 == 7'b0100000);
                        alu_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
                    end
                endcase
            end
            7'b0110011: begin // OP and M extension
                writes = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; b_imm = 1'b0;
                if (funct7 == 7'b0000001) begin
                    legal = 1'b1; is_mdu = 1'b1; wb_sel = `WB_MDU;
                end else begin
                    legal = (funct7 == 7'b0000000) ||
                            (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101));
                    case (funct3)
                        3'b000: alu_op = funct7[5] ? `ALU_SUB : `ALU_ADD;
                        3'b001: alu_op = `ALU_SLL;
                        3'b010: alu_op = `ALU_SLT;
                        3'b011: alu_op = `ALU_SLTU;
                        3'b100: alu_op = `ALU_XOR;
                        3'b101: alu_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
                        3'b110: alu_op = `ALU_OR;
                        default: alu_op = `ALU_AND;
                    endcase
                end
            end
            7'b0001111: begin // FENCE (no-op on one hart), FENCE.I
                legal = (funct3 == 3'b000) || (funct3 == 3'b001);
                is_fencei = (funct3 == 3'b001);
            end
            7'b1110011: begin // SYSTEM
                if (funct3 == 3'b000) begin
                    is_ecall  = (insn == 32'h0000_0073);
                    is_ebreak = (insn == 32'h0010_0073);
                    is_mret   = (insn == 32'h3020_0073);
                    legal = is_ecall || is_ebreak || is_mret || (insn == 32'h1050_0073); // WFI = no-op
                end else if (funct3 != 3'b100) begin
                    legal = 1'b1; is_csr = 1'b1; writes = 1'b1; wb_sel = `WB_CSR;
                    uses_rs1 = !funct3[2];
                end
            end
            7'b0000111: begin // FLW, FLD (FLD is two word accesses)
                legal = FPU && (funct3 == 3'b010 || funct3 == 3'b011);
                is_fp = 1'b1; is_load = 1'b1; uses_rs1 = 1'b1; fwrites = 1'b1; wb_sel = `WB_MEM;
                fp_dbl = funct3[0];
            end
            7'b0100111: begin // FSW, FSD
                legal = FPU && (funct3 == 3'b010 || funct3 == 3'b011);
                is_fp = 1'b1; is_store = 1'b1; uses_rs1 = 1'b1; uses_frs2 = 1'b1; imm = imm_s;
                fp_dbl = funct3[0];
            end
            7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin // FMADD, FMSUB, FNMSUB, FNMADD
                legal = FPU && fmt_ok && rm_ok;
                is_fp = 1'b1; fp_unit = 1'b1; fwrites = 1'b1; rm_used = 1'b1;
                uses_frs1 = 1'b1; uses_frs2 = 1'b1; uses_frs3 = 1'b1;
                fp_op = `FOP_MADD + {3'b000, opcode[3:2]};
            end
            7'b1010011: begin // OP-FP
                is_fp = 1'b1; fp_unit = 1'b1;
                case (funct5)
                    5'b00000, 5'b00001, 5'b00010, 5'b00011: begin // FADD, FSUB, FMUL, FDIV
                        fop_ok = 1'b1; fwrites = 1'b1; rm_used = 1'b1; uses_frs1 = 1'b1; uses_frs2 = 1'b1;
                        fp_op = (funct5[1:0] == 2'b00) ? `FOP_ADD : (funct5[1:0] == 2'b01) ? `FOP_SUB :
                                (funct5[1:0] == 2'b10) ? `FOP_MUL : `FOP_DIV;
                    end
                    5'b01011: begin // FSQRT
                        fop_ok = (rs2 == 5'd0); fwrites = 1'b1; rm_used = 1'b1; uses_frs1 = 1'b1;
                        fp_op = `FOP_SQRT;
                    end
                    5'b00100: begin // FSGNJ, FSGNJN, FSGNJX
                        fop_ok = (funct3 <= 3'b010); fwrites = 1'b1; uses_frs1 = 1'b1; uses_frs2 = 1'b1;
                        fp_op = (funct3[1:0] == 2'b00) ? `FOP_SGNJ : (funct3[1:0] == 2'b01) ? `FOP_SGNJN : `FOP_SGNJX;
                    end
                    5'b00101: begin // FMIN, FMAX
                        fop_ok = (funct3 <= 3'b001); fwrites = 1'b1; uses_frs1 = 1'b1; uses_frs2 = 1'b1;
                        fp_op = funct3[0] ? `FOP_MAX : `FOP_MIN;
                    end
                    5'b01000: begin // FCVT.S.D (rs2 = 1), FCVT.D.S (rs2 = 0): rs2 names the source format
                        fop_ok = (rs2 == {4'b0000, !insn[25]}); fwrites = 1'b1; rm_used = 1'b1; uses_frs1 = 1'b1;
                        fp_op = `FOP_F2F;
                    end
                    5'b10100: begin // FLE, FLT, FEQ
                        fop_ok = (funct3 <= 3'b010); writes = 1'b1; wb_sel = `WB_FPU;
                        uses_frs1 = 1'b1; uses_frs2 = 1'b1;
                        fp_op = (funct3[1:0] == 2'b00) ? `FOP_LE : (funct3[1:0] == 2'b01) ? `FOP_LT : `FOP_EQ;
                    end
                    5'b11000: begin // FCVT.W, FCVT.WU
                        fop_ok = (rs2[4:1] == 4'd0); writes = 1'b1; wb_sel = `WB_FPU; rm_used = 1'b1;
                        uses_frs1 = 1'b1;
                        fp_op = rs2[0] ? `FOP_F2IU : `FOP_F2I;
                    end
                    5'b11010: begin // FCVT.fmt.W, FCVT.fmt.WU
                        fop_ok = (rs2[4:1] == 4'd0); fwrites = 1'b1; rm_used = 1'b1; uses_rs1 = 1'b1;
                        fp_op = rs2[0] ? `FOP_IU2F : `FOP_I2F;
                    end
                    5'b11100: begin // FMV.X.W (no FMV.X.D on RV32), FCLASS
                        fop_ok = (rs2 == 5'd0) && ((funct3 == 3'b000 && !insn[25]) || funct3 == 3'b001);
                        writes = 1'b1; wb_sel = `WB_FPU; uses_frs1 = 1'b1;
                        fp_op = funct3[0] ? `FOP_CLASS : `FOP_MVXW;
                    end
                    5'b11110: begin // FMV.W.X
                        fop_ok = (rs2 == 5'd0) && (funct3 == 3'b000) && !insn[25];
                        fwrites = 1'b1; uses_rs1 = 1'b1;
                        fp_op = `FOP_MVWX;
                    end
                    default: fop_ok = 1'b0;
                endcase
                legal = FPU && fmt_ok && fop_ok && (!rm_used || rm_ok);
            end
            default: legal = 1'b0;
        endcase

        if (insn[1:0] != 2'b11)
            legal = 1'b0;
        illegal = !legal;
        if (!legal) begin
            writes = 1'b0;
            is_branch = 1'b0; is_jal = 1'b0; is_jalr = 1'b0;
            is_load = 1'b0; is_store = 1'b0; is_mdu = 1'b0; is_csr = 1'b0;
            is_ecall = 1'b0; is_ebreak = 1'b0; is_mret = 1'b0; is_fencei = 1'b0;
            uses_rs1 = 1'b0; uses_rs2 = 1'b0;
            is_fp = 1'b0; fp_unit = 1'b0; fwrites = 1'b0; rm_used = 1'b0;
            uses_frs1 = 1'b0; uses_frs2 = 1'b0; uses_frs3 = 1'b0;
        end
    end

    assign frd_we = fwrites;
    assign fp_rm_dyn = rm_used && (funct3 == 3'b111);

    assign rd_we = writes && (rd != 5'd0);
    assign is_div = is_mdu && funct3[2];
    // CSRRW/CSRRWI always write; the set/clear forms only when rs1/uimm != 0
    assign csr_writes = is_csr && ((funct3[1:0] == 2'b01) || (rs1 != 5'd0));
endmodule
