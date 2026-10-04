// Simulation top for core A: the single-cycle core plus a combinational
// "magic" memory (1 MiB RAM at 0x80000000) and the I/O registers.
// Not synthesisable as a whole (the memory is a plain array loaded with
// $readmemh); synthesis uses core_single alone.
`include "rv_defs.svh"

module sim_top_single (
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
    // I/O register writes, sampled by the harness before the clock edge
    output logic        mmio_we,
    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wdata
);
    localparam int WORDS = `RAM_BYTES / 4;
    logic [31:0] ram [0:WORDS-1];
    string program_hex;

    initial begin
        for (int i = 0; i < WORDS; i++) ram[i] = 32'd0;
        if ($value$plusargs("program=%s", program_hex)) $readmemh(program_hex, ram);
    end

    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_rdata, dmem_wdata;
    logic [3:0]  dmem_wmask;
    logic        dmem_re;

    core_single u_core (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
        .dmem_wmask(dmem_wmask), .dmem_wdata(dmem_wdata),
        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_trap(commit_trap), .commit_cause(commit_cause), .commit_rd_we(commit_rd_we),
        .commit_rd(commit_rd), .commit_rd_val(commit_rd_val), .commit_mem_we(commit_mem_we),
        .commit_mem_addr(commit_mem_addr), .commit_mem_wdata(commit_mem_wdata),
        .commit_mem_wmask(commit_mem_wmask), .perf_events(perf_events));

    // RAM is every address with bit 31 set, wrapped to 1 MiB; I/O reads as 0.
    assign imem_rdata = imem_addr[31] ? ram[imem_addr[19:2]] : 32'd0;
    assign dmem_rdata = dmem_addr[31] ? ram[dmem_addr[19:2]] : 32'd0;

    always_ff @(posedge clk)
        if (dmem_addr[31])
            for (int b = 0; b < 4; b++)
                if (dmem_wmask[b]) ram[dmem_addr[19:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];

    assign mmio_we = !dmem_addr[31] && dmem_wmask != 4'b0000;
    assign mmio_addr = dmem_addr;
    assign mmio_wdata = dmem_wdata;

    logic unused;
    assign unused = &{1'b0, dmem_re, imem_addr[1:0], dmem_addr[1:0]};
endmodule
