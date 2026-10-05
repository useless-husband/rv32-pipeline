// Decoder for the F and D instructions (combinational).  Instantiated by
// decoder.sv when FPU = 1; its outputs override the integer decode for the
// five F/D major opcodes.  `legal` covers everything that can be told from
// the instruction word; mstatus.FS and a dynamic rounding mode's frm value
// are checked in EX.
`include "rv_defs.svh"

module fp_decoder (
    input  logic [31:0] insn,
    output logic        hit,        // one of the F/D major opcodes
    output logic        legal,
    output logic        fp_unit,    // executes in the FPU
    output logic [4:0]  fp_op,      // FOP_*
    output logic        fp_dbl,     // double format (FLD/FSD: an 8-byte access)
    output logic        rm_used,    // funct3 is a rounding mode
    output logic        fwrites,    // writes f register rd
    output logic        uses_frs1,
    output logic        uses_frs2,
    output logic        uses_frs3,
    output logic        is_load,    // FLW, FLD
    output logic        is_store,   // FSW, FSD
    output logic        uses_xrs1,  // reads integer register rs1
    output logic        xwrites     // writes integer register rd
);
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [4:0] funct5, rs2;
    logic       fmt_ok, rm_ok, fop_ok;

    assign opcode = insn[6:0];
    assign funct3 = insn[14:12];
    assign funct5 = insn[31:27];
    assign rs2    = insn[24:20];
    assign fmt_ok = (insn[26] == 1'b0);                       // S (00) or D (01)
    assign rm_ok  = (funct3 <= 3'b100) || (funct3 == 3'b111); // 101 and 110 are reserved

    always_comb begin
        hit = 1'b0;
        legal = 1'b0;
        fp_unit = 1'b0;
        fp_op = `FOP_ADD;
        fp_dbl = insn[25];
        rm_used = 1'b0;
        fwrites = 1'b0;
        uses_frs1 = 1'b0;
        uses_frs2 = 1'b0;
        uses_frs3 = 1'b0;
        is_load = 1'b0;
        is_store = 1'b0;
        uses_xrs1 = 1'b0;
        xwrites = 1'b0;
        fop_ok = 1'b0;

        case (opcode)
            7'b0000111: begin // FLW, FLD (FLD is two word accesses)
                legal = (funct3 == 3'b010 || funct3 == 3'b011);
                hit = 1'b1; is_load = 1'b1; uses_xrs1 = 1'b1; fwrites = 1'b1;
                fp_dbl = funct3[0];
            end
            7'b0100111: begin // FSW, FSD
                legal = (funct3 == 3'b010 || funct3 == 3'b011);
                hit = 1'b1; is_store = 1'b1; uses_xrs1 = 1'b1; uses_frs2 = 1'b1;
                fp_dbl = funct3[0];
            end
            7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin // FMADD, FMSUB, FNMSUB, FNMADD
                legal = fmt_ok && rm_ok;
                hit = 1'b1; fp_unit = 1'b1; fwrites = 1'b1; rm_used = 1'b1;
                uses_frs1 = 1'b1; uses_frs2 = 1'b1; uses_frs3 = 1'b1;
                fp_op = `FOP_MADD + {3'b000, opcode[3:2]};
            end
            7'b1010011: begin // OP-FP
                hit = 1'b1; fp_unit = 1'b1;
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
                        fop_ok = (funct3 <= 3'b010); xwrites = 1'b1;
                        uses_frs1 = 1'b1; uses_frs2 = 1'b1;
                        fp_op = (funct3[1:0] == 2'b00) ? `FOP_LE : (funct3[1:0] == 2'b01) ? `FOP_LT : `FOP_EQ;
                    end
                    5'b11000: begin // FCVT.W, FCVT.WU
                        fop_ok = (rs2[4:1] == 4'd0); xwrites = 1'b1; rm_used = 1'b1;
                        uses_frs1 = 1'b1;
                        fp_op = rs2[0] ? `FOP_F2IU : `FOP_F2I;
                    end
                    5'b11010: begin // FCVT.fmt.W, FCVT.fmt.WU
                        fop_ok = (rs2[4:1] == 4'd0); fwrites = 1'b1; rm_used = 1'b1; uses_xrs1 = 1'b1;
                        fp_op = rs2[0] ? `FOP_IU2F : `FOP_I2F;
                    end
                    5'b11100: begin // FMV.X.W (no FMV.X.D on RV32), FCLASS
                        fop_ok = (rs2 == 5'd0) && ((funct3 == 3'b000 && !insn[25]) || funct3 == 3'b001);
                        xwrites = 1'b1; uses_frs1 = 1'b1;
                        fp_op = funct3[0] ? `FOP_CLASS : `FOP_MVXW;
                    end
                    5'b11110: begin // FMV.W.X
                        fop_ok = (rs2 == 5'd0) && (funct3 == 3'b000) && !insn[25];
                        fwrites = 1'b1; uses_xrs1 = 1'b1;
                        fp_op = `FOP_MVWX;
                    end
                    default: fop_ok = 1'b0;
                endcase
                legal = fmt_ok && fop_ok && (!rm_used || rm_ok);
            end
            default: ;
        endcase
    end

    logic unused;
    assign unused = &{1'b0, insn[11:7], insn[19:15]};
endmodule
