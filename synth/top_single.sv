// Synthesis wrapper for core A: the core with its memory ports as the chip's
// ports.  The commit port and other verification-only outputs are left
// unconnected so synthesis removes the logic that only feeds them.
`include "rv_defs.svh"

module top_single (
    input  logic        clk,
    input  logic        rst,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,
    output logic        dmem_re,
    input  logic [31:0] dmem_rdata,
    output logic [3:0]  dmem_wmask,
    output logic [31:0] dmem_wdata
);
    core_single u_core (
        .clk(clk), .rst(rst), .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
        .dmem_wmask(dmem_wmask), .dmem_wdata(dmem_wdata),
        .commit_valid(), .commit_pc(), .commit_insn(), .commit_trap(), .commit_cause(),
        .commit_rd_we(), .commit_rd(), .commit_rd_val(), .commit_mem_we(), .commit_mem_addr(),
        .commit_mem_wdata(), .commit_mem_wmask(), .perf_events());
endmodule
