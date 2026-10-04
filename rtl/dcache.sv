// Data cache: 2-way set associative, 16-byte lines, write-back,
// write-allocate, one LRU bit per set.  Addresses with bit 31 clear are I/O
// and bypass the cache (one uncached bus transaction per access).
//
// Like the I-cache, the tag and data arrays are read synchronously (block
// RAM): the pipeline gives the address of the access that will be in MEM in
// the next cycle (addr_next) and the hit check happens in MEM.  A store hit
// writes the data array at the end of its MEM cycle; the access behind it
// has read the same array at that very edge and sees the old bytes, so a
// one-entry bypass register merges the store's bytes into the next read.
//
// Miss: pick a victim (an invalid way, else the LRU way); if it is dirty,
// write the line back; read the new line; re-read the arrays for one cycle;
// then the access hits.  FENCE.I asks for a flush: every dirty line is
// written back (valid lines stay valid and become clean).
module dcache #(
    parameter int SETS = 128            // sets per way; capacity = 2 * SETS * 16 bytes
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [31:0]  addr_next,
    input  logic         req,           // a load or store is in MEM
    input  logic         we,
    input  logic [31:0]  addr,
    input  logic [31:0]  wdata,         // store data in its byte lanes
    input  logic [3:0]   wmask,
    output logic         ready,         // the access completes this cycle
    output logic [31:0]  rdata,         // the addressed word (loads)
    input  logic         flush_req,
    output logic         flush_done,
    output logic         ev_access,
    output logic         ev_miss,
    output logic         ev_wb,
    output logic         bus_req,
    output logic         bus_we,
    output logic [31:0]  bus_addr,
    output logic [127:0] bus_wdata,
    output logic [15:0]  bus_wstrb,
    input  logic         bus_ack,
    input  logic [127:0] bus_rdata
);
    localparam int IW = $clog2(SETS);
    localparam int TW = 28 - IW;
    localparam logic [3:0] IDLE = 4'd0, WB = 4'd1, REFILL = 4'd2, WAIT = 4'd3, UNC = 4'd4,
                           UNC_DONE = 4'd5, F_RD = 4'd6, F_CHK = 4'd7, F_WB = 4'd8, F_END = 4'd9;

    logic [127:0]  data0 [0:SETS-1];
    logic [127:0]  data1 [0:SETS-1];
    logic [TW-1:0] tag0  [0:SETS-1];
    logic [TW-1:0] tag1  [0:SETS-1];
    logic [SETS-1:0] valid0, valid1, dirty0, dirty1, lru;  // lru[s] = way to evict next

    logic [3:0]    state;
    logic [IW-1:0] idx, ra, fidx;
    logic [TW-1:0] tag_a;
    logic [127:0]  d0_q, d1_q, d0, d1, line;
    logic [TW-1:0] t0_q, t1_q;
    logic          h0, h1, hit, cacheable, idle_hit;
    logic          victim, victim_q, fway;
    logic [127:0]  wb_line;
    logic [31:0]   wb_addr, unc_q;
    logic [15:0]   st_strb;

    assign idx = addr[4 +: IW];
    assign tag_a = addr[31:4+IW];
    assign cacheable = addr[31];
    assign st_strb = {12'd0, wmask} << (4 * addr[3:2]);
    assign ra = (state == F_RD || state == F_CHK || state == F_WB) ? fidx : addr_next[4 +: IW];

    // ------------------------------------------------------------------ arrays
    logic          wr0, wr1;
    logic [IW-1:0] widx;
    logic [127:0]  wline;
    logic [15:0]   wstrb;

    always_ff @(posedge clk) begin
        d0_q <= data0[ra];
        d1_q <= data1[ra];
        t0_q <= tag0[ra];
        t1_q <= tag1[ra];
        for (int b = 0; b < 16; b++) begin
            if (wr0 && wstrb[b]) data0[widx][8*b +: 8] <= wline[8*b +: 8];
            if (wr1 && wstrb[b]) data1[widx][8*b +: 8] <= wline[8*b +: 8];
        end
        if (state == REFILL && bus_ack) begin
            if (!victim_q) tag0[idx] <= tag_a;
            else tag1[idx] <= tag_a;
        end
    end

    // store-to-load bypass for the read that coincided with a store's write
    logic          byp_v, byp_way;
    logic [IW-1:0] byp_idx;
    logic [127:0]  byp_line;
    logic [15:0]   byp_strb;
    logic [127:0]  byp_mask;

    always_comb begin
        for (int b = 0; b < 16; b++) byp_mask[8*b +: 8] = {8{byp_strb[b]}};
        d0 = d0_q;
        d1 = d1_q;
        if (byp_v && byp_idx == idx && !byp_way) d0 = (d0_q & ~byp_mask) | (byp_line & byp_mask);
        if (byp_v && byp_idx == idx && byp_way) d1 = (d1_q & ~byp_mask) | (byp_line & byp_mask);
    end

    // ---------------------------------------------------------------- lookup
    assign h0 = valid0[idx] && t0_q == tag_a;
    assign h1 = valid1[idx] && t1_q == tag_a;
    assign hit = h0 || h1;
    assign idle_hit = (state == IDLE) && req && cacheable && hit;
    assign line = h1 ? d1 : d0;
    assign ready = idle_hit || (state == UNC_DONE);
    assign rdata = (state == UNC_DONE) ? unc_q : line[32*addr[3:2] +: 32];
    assign victim = !valid0[idx] ? 1'b0 : !valid1[idx] ? 1'b1 : lru[idx];
    assign flush_done = (state == F_END);

    always_comb begin
        wr0 = 1'b0;
        wr1 = 1'b0;
        widx = idx;
        wline = {4{wdata}};
        wstrb = st_strb;
        if (idle_hit && we) begin
            wr0 = h0;
            wr1 = h1;
        end else if (state == REFILL && bus_ack) begin
            wr0 = !victim_q;
            wr1 = victim_q;
            wline = bus_rdata;
            wstrb = 16'hffff;
        end
    end

    // ------------------------------------------------------------------- bus
    always_comb begin
        bus_req = 1'b0;
        bus_we = 1'b0;
        bus_addr = {addr[31:4], 4'b0000};
        bus_wdata = wb_line;
        bus_wstrb = 16'hffff;
        case (state)
            WB, F_WB: begin bus_req = 1'b1; bus_we = 1'b1; bus_addr = wb_addr; end
            REFILL: bus_req = 1'b1;
            UNC: begin
                bus_req = 1'b1;
                bus_we = we;
                bus_wdata = {4{wdata}};
                bus_wstrb = we ? st_strb : 16'h0000;
            end
            default: ;
        endcase
    end

    assign ev_access = idle_hit;
    assign ev_miss = (state == IDLE) && req && cacheable && !hit;
    assign ev_wb = (state == WB || state == F_WB) && bus_ack;

    // ------------------------------------------------------------ controller
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            valid0 <= '0;
            valid1 <= '0;
            dirty0 <= '0;
            dirty1 <= '0;
            lru <= '0;
            byp_v <= 1'b0;
        end else begin
            byp_v <= idle_hit && we;
            byp_way <= h1;
            byp_idx <= idx;
            byp_line <= {4{wdata}};
            byp_strb <= st_strb;
            case (state)
                IDLE: begin
                    if (idle_hit) begin
                        lru[idx] <= !h1;
                        if (we && h0) dirty0[idx] <= 1'b1;
                        if (we && h1) dirty1[idx] <= 1'b1;
                    end else if (req && cacheable) begin
                        victim_q <= victim;
                        if (victim ? (valid1[idx] && dirty1[idx]) : (valid0[idx] && dirty0[idx])) begin
                            wb_line <= victim ? d1 : d0;
                            wb_addr <= {victim ? t1_q : t0_q, idx, 4'b0000};
                            state <= WB;
                        end else begin
                            state <= REFILL;
                        end
                    end else if (req) begin
                        state <= UNC;
                    end else if (flush_req) begin
                        fidx <= '0;
                        state <= F_RD;
                    end
                end
                WB: if (bus_ack) state <= REFILL;
                REFILL: if (bus_ack) begin
                    if (!victim_q) begin valid0[idx] <= 1'b1; dirty0[idx] <= 1'b0; end
                    else begin valid1[idx] <= 1'b1; dirty1[idx] <= 1'b0; end
                    lru[idx] <= !victim_q;
                    state <= WAIT;
                end
                WAIT: state <= IDLE;
                UNC: if (bus_ack) begin
                    unc_q <= bus_rdata[32*addr[3:2] +: 32];
                    state <= UNC_DONE;
                end
                UNC_DONE: state <= IDLE;
                F_RD: state <= F_CHK;
                F_CHK: begin
                    if (valid0[fidx] && dirty0[fidx]) begin
                        wb_line <= d0_q;
                        wb_addr <= {t0_q, fidx, 4'b0000};
                        fway <= 1'b0;
                        state <= F_WB;
                    end else if (valid1[fidx] && dirty1[fidx]) begin
                        wb_line <= d1_q;
                        wb_addr <= {t1_q, fidx, 4'b0000};
                        fway <= 1'b1;
                        state <= F_WB;
                    end else if (&fidx) begin  // last set (SETS is a power of two)
                        state <= F_END;
                    end else begin
                        fidx <= fidx + 1'b1;
                        state <= F_RD;
                    end
                end
                F_WB: if (bus_ack) begin
                    if (!fway) dirty0[fidx] <= 1'b0;
                    else dirty1[fidx] <= 1'b0;
                    state <= F_CHK;
                end
                default: state <= IDLE;  // F_END
            endcase
        end
    end

    logic unused;
    assign unused = &{1'b0, addr[1:0], addr_next[31:4+IW], addr_next[3:0]};
endmodule
