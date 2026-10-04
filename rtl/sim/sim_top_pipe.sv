// Simulation top for core B: the pipelined core (with its caches) and the
// latency-configurable memory model.  Parameters can be overridden with -G
// options at build time (make PIPE_G=...) to measure other configurations.
`include "rv_defs.svh"

module sim_top_pipe #(
    parameter int MEM_LATENCY = 10,
    parameter int ICACHE_SETS = 256,
    parameter int DCACHE_SETS = 128,
    parameter int BTB_ENTRIES = 32,
    parameter int BHT_ENTRIES = 256,
    parameter bit BP_ENABLE = 1'b1
) (
    input  logic        clk,
    input  logic        rst,
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
    output logic [`NUM_EVENTS-1:0] perf_events,
    output logic        mmio_we,
    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wdata,
    output logic [31:0] dbg_f_pc,
    output logic [15:0] dbg_f_seq,
    output logic        dbg_d_valid,
    output logic [15:0] dbg_d_seq,
    output logic [31:0] dbg_d_pc,
    output logic [31:0] dbg_d_insn,
    output logic        dbg_e_valid,
    output logic [15:0] dbg_e_seq,
    output logic        dbg_m_valid,
    output logic [15:0] dbg_m_seq,
    output logic        dbg_w_valid,
    output logic [15:0] dbg_w_seq,
    output logic [5:0]  dbg_why
);
    logic         bus_req, bus_we, bus_ack;
    logic [31:0]  bus_addr;
    logic [127:0] bus_wdata, bus_rdata;
    logic [15:0]  bus_wstrb;

    core_pipe #(.ICACHE_SETS(ICACHE_SETS), .DCACHE_SETS(DCACHE_SETS), .BTB_ENTRIES(BTB_ENTRIES),
                .BHT_ENTRIES(BHT_ENTRIES), .BP_ENABLE(BP_ENABLE)) u_core (
        .clk(clk), .rst(rst),
        .bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_wstrb(bus_wstrb), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_trap(commit_trap), .commit_cause(commit_cause), .commit_rd_we(commit_rd_we),
        .commit_rd(commit_rd), .commit_rd_val(commit_rd_val), .commit_mem_we(commit_mem_we),
        .commit_mem_addr(commit_mem_addr), .commit_mem_wdata(commit_mem_wdata),
        .commit_mem_wmask(commit_mem_wmask), .perf_events(perf_events),
        .dbg_f_pc(dbg_f_pc), .dbg_f_seq(dbg_f_seq), .dbg_d_valid(dbg_d_valid), .dbg_d_seq(dbg_d_seq),
        .dbg_d_pc(dbg_d_pc), .dbg_d_insn(dbg_d_insn), .dbg_e_valid(dbg_e_valid), .dbg_e_seq(dbg_e_seq),
        .dbg_m_valid(dbg_m_valid), .dbg_m_seq(dbg_m_seq), .dbg_w_valid(dbg_w_valid),
        .dbg_w_seq(dbg_w_seq), .dbg_why(dbg_why));

    mem_model #(.LATENCY(MEM_LATENCY)) u_mem (
        .clk(clk), .rst(rst), .req(bus_req), .we(bus_we), .addr(bus_addr), .wdata(bus_wdata),
        .wstrb(bus_wstrb), .ack(bus_ack), .rdata(bus_rdata),
        .mmio_we(mmio_we), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata));
endmodule
