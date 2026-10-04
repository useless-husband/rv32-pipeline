// Synthesis wrapper for core B: the pipelined core with its caches; the
// memory bus is the chip's port.  Commit port and viewer probes are left
// unconnected so synthesis removes the logic that only feeds them.
`include "rv_defs.svh"

module top_pipe (
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
    core_pipe u_core (
        .clk(clk), .rst(rst), .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_wstrb(bus_wstrb), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
        .commit_valid(), .commit_pc(), .commit_insn(), .commit_trap(), .commit_cause(),
        .commit_rd_we(), .commit_rd(), .commit_rd_val(), .commit_mem_we(), .commit_mem_addr(),
        .commit_mem_wdata(), .commit_mem_wmask(), .perf_events(),
        .dbg_f_pc(), .dbg_f_seq(), .dbg_d_valid(), .dbg_d_seq(), .dbg_d_pc(), .dbg_d_insn(),
        .dbg_e_valid(), .dbg_e_seq(), .dbg_m_valid(), .dbg_m_seq(), .dbg_w_valid(), .dbg_w_seq(),
        .dbg_why());
endmodule
