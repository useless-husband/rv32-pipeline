// The rounding decision shared by every rounding site: given the last kept
// bit (lsb), the first discarded bit (g) and whether anything nonzero lies
// below it (s), does the magnitude round up?
`include "rv_defs.svh"

module fp_roundup (
    input  logic [2:0] rm,
    input  logic       sign,
    input  logic       lsb,
    input  logic       g,
    input  logic       s,
    output logic       up
);
    always_comb begin
        case (rm)
            `RM_RNE: up = g && (s || lsb);       // nearest, ties to even
            `RM_RTZ: up = 1'b0;                  // toward zero
            `RM_RDN: up = sign && (g || s);      // toward minus infinity
            `RM_RUP: up = !sign && (g || s);     // toward plus infinity
            default: up = g;                     // RMM: nearest, ties away from zero
        endcase
    end
endmodule
