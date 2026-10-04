// Branch predictor for the pipelined core: a direct-mapped branch target
// buffer (BTB) plus a table of 2-bit saturating counters (BHT).
//
// Lookup (IF, combinational): if the BTB holds the fetch PC, an unconditional
// jump is predicted taken to the stored target and a conditional branch is
// predicted taken when its counter is 2 or 3.  Otherwise: not taken.
// Update (EX, when a branch or jump resolves): counters move toward the
// outcome; taken branches and all jumps (re)write their BTB entry.
// ENABLE=0 turns it into "always predict not taken", for comparison.
module bpred #(
    parameter int BTB_ENTRIES = 32,   // power of two
    parameter int BHT_ENTRIES = 256,  // power of two
    parameter bit ENABLE = 1'b1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] pc,
    output logic        pred_taken,
    output logic [31:0] pred_target,
    input  logic        upd_valid,
    input  logic        upd_branch,    // conditional branch
    input  logic        upd_jump,      // JAL or JALR
    input  logic [31:0] upd_pc,
    input  logic        upd_taken,
    input  logic [31:0] upd_target
);
    localparam int BI = $clog2(BTB_ENTRIES);
    localparam int HI = $clog2(BHT_ENTRIES);
    localparam int TW = 30 - BI;

    logic          btb_valid [0:BTB_ENTRIES-1];
    logic          btb_jump  [0:BTB_ENTRIES-1];
    logic [TW-1:0] btb_tag   [0:BTB_ENTRIES-1];
    logic [29:0]   btb_tgt   [0:BTB_ENTRIES-1];
    logic [1:0]    bht       [0:BHT_ENTRIES-1];

    logic [BI-1:0] li, ui;
    logic [HI-1:0] lh, uh;
    logic          hit;

    assign li = pc[2 +: BI];
    assign lh = pc[2 +: HI];
    assign ui = upd_pc[2 +: BI];
    assign uh = upd_pc[2 +: HI];

    assign hit = btb_valid[li] && btb_tag[li] == pc[31:2+BI];
    assign pred_taken = ENABLE && hit && (btb_jump[li] || bht[lh][1]);
    assign pred_target = {btb_tgt[li], 2'b00};

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < BTB_ENTRIES; i++) btb_valid[i] <= 1'b0;
            for (int i = 0; i < BHT_ENTRIES; i++) bht[i] <= 2'b01;  // weakly not taken
        end else if (upd_valid) begin
            if (upd_branch) begin
                if (upd_taken && bht[uh] != 2'b11) bht[uh] <= bht[uh] + 2'b01;
                if (!upd_taken && bht[uh] != 2'b00) bht[uh] <= bht[uh] - 2'b01;
            end
            if (upd_taken && (upd_branch || upd_jump)) begin
                btb_valid[ui] <= 1'b1;
                btb_jump[ui] <= upd_jump;
                btb_tag[ui] <= upd_pc[31:2+BI];
                btb_tgt[ui] <= upd_target[31:2];
            end
        end
    end

    logic unused;
    assign unused = &{1'b0, pc[1:0], upd_pc[1:0], upd_target[1:0]};
endmodule
