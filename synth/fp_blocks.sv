// Three building blocks on their own, registers in and out, to see what fits
// in one clock cycle (make sta-blocks).  They are the measurements behind
// the decision to make the FPU multi-cycle (docs/report.md section 12.4);
// they are not part of either core.
module blk_mul53x53 (input logic clk, input logic [52:0] a, b, output logic [105:0] p);
    logic [52:0] ar, br;
    always_ff @(posedge clk) begin
        ar <= a;
        br <= b;
        p <= {53'd0, ar} * {53'd0, br};
    end
endmodule

module blk_mul53x17 (input logic clk, input logic [52:0] a, input logic [16:0] b, output logic [69:0] p);
    logic [52:0] ar;
    logic [16:0] br;
    always_ff @(posedge clk) begin
        ar <= a;
        br <= b;
        p <= {17'd0, ar} * {53'd0, br};
    end
endmodule

module blk_add165 (input logic clk, input logic [164:0] a, b, output logic [164:0] s);
    logic [164:0] ar, br;
    always_ff @(posedge clk) begin
        ar <= a;
        br <= b;
        s <= ar + br;
    end
endmodule
