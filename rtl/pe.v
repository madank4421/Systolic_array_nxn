// pe.v
// Processing Element with explicit operand isolation on the multiplier.
//
// WHY: mac_enable already prevents mac_out from *updating* when either
// operand is zero. But without isolation, the raw a_in/b_in bit patterns
// still feed the multiplier combinationally every single cycle, so the
// multiplier's internal logic keeps switching even on cycles whose
// product will be thrown away. Gating a_in/b_in to a fixed '0 whenever
// mac_enable is low removes that switching activity at its source,
// which synthesis/PnR tools translate into a measurable reduction in
// multiplier dynamic power (visible in your OpenSTA / power reports as
// lower switching-activity-driven power on the mult cells).

module pe #(
  parameter ARRAY_SIZE = 4,
  parameter DATA_WIDTH = 8,
  parameter ACC_WIDTH  = (2 * DATA_WIDTH) + $clog2(ARRAY_SIZE)
)
(
  input  logic [DATA_WIDTH-1:0] a_in,
  input  logic [DATA_WIDTH-1:0] b_in,
  input  logic clk,
  input  logic rst,
  input  logic clear,
  output logic [DATA_WIDTH-1:0] a_out,
  output logic [DATA_WIDTH-1:0] b_out,
  output logic [ACC_WIDTH-1:0]  mac_out
);

  logic mac_enable;
  logic [DATA_WIDTH-1:0] a_gated, b_gated;

  // Sparsity detection (unchanged from your original design)
  assign mac_enable = (a_in != '0) && (b_in != '0);

  // ---- Operand isolation ----
  // Force the multiplier operands to a constant 0 whenever the product
  // would be discarded anyway. This is the standard "AND-isolation"
  // low-power technique: holding inputs constant (instead of letting
  // them toggle freely) collapses glitch/switching power in the
  // downstream combinational multiplier tree.
  assign a_gated = mac_enable ? a_in : '0;
  assign b_gated = mac_enable ? b_in : '0;

   always_ff @(posedge clk) begin
    if (rst) begin
      mac_out <= '0;
      a_out   <= '0;
      b_out   <= '0;
    end
    else begin
      a_out <= a_in;
      b_out <= b_in;
      if (clear)
        mac_out <= '0;
      else if (mac_enable)
        mac_out <= mac_out + (a_gated * b_gated);
    end
  end

endmodule
