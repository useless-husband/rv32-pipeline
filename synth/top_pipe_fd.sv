// Synthesis wrapper for core B with the floating-point unit (RV32IMFD).
module top_pipe_fd (
    input  logic         clk,
    input  logic         rst,
    output logic         bus_req,
    output logic         bus_we,
    output logic [31:0]  bus_addr,
    output logic [127:0] bus_wdata,
    output logic [15:0]  bus_wstrb,
    input  logic         bus_ack,
    input  logic [127:0] bus_rdata
);
    top_pipe #(.FPU(1'b1)) u_top (
        .clk(clk), .rst(rst), .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_wstrb(bus_wstrb), .bus_ack(bus_ack), .bus_rdata(bus_rdata));
endmodule
