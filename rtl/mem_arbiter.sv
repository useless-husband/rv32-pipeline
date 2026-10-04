// Two-master arbiter in front of the memory bus.  The D-cache (master 0)
// wins when both request in the same cycle; a grant is held until the
// memory acknowledges.  Bus protocol: a master holds req (and its fields)
// until it sees a one-cycle ack; read data is valid with the ack.
module mem_arbiter (
    input  logic         clk,
    input  logic         rst,
    input  logic         m0_req,
    input  logic         m0_we,
    input  logic [31:0]  m0_addr,
    input  logic [127:0] m0_wdata,
    input  logic [15:0]  m0_wstrb,
    output logic         m0_ack,
    input  logic         m1_req,
    input  logic         m1_we,
    input  logic [31:0]  m1_addr,
    input  logic [127:0] m1_wdata,
    input  logic [15:0]  m1_wstrb,
    output logic         m1_ack,
    output logic         bus_req,
    output logic         bus_we,
    output logic [31:0]  bus_addr,
    output logic [127:0] bus_wdata,
    output logic [15:0]  bus_wstrb,
    input  logic         bus_ack
);
    logic busy, owner, sel;

    assign sel = busy ? owner : !m0_req;
    assign bus_req   = sel ? m1_req   : m0_req;
    assign bus_we    = sel ? m1_we    : m0_we;
    assign bus_addr  = sel ? m1_addr  : m0_addr;
    assign bus_wdata = sel ? m1_wdata : m0_wdata;
    assign bus_wstrb = sel ? m1_wstrb : m0_wstrb;
    assign m0_ack = bus_ack && !sel;
    assign m1_ack = bus_ack && sel;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            owner <= 1'b0;
        end else if (!busy) begin
            if (bus_req && !bus_ack) begin
                busy <= 1'b1;
                owner <= sel;
            end
        end else if (bus_ack) begin
            busy <= 1'b0;
        end
    end
endmodule
