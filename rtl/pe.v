// pe.v
// Area-optimised Processing Element.
//
// Changes vs. previous version:
//   - mac_enable and operand isolation removed. If either operand is 0 the
//     product is 0, so mac_out + 0 already leaves mac_out unchanged.
//   - No reset on a_out / b_out. The controller streams zeros whenever it is
//     not in LOAD, so the pipeline flushes by itself.
//   - New 'clear' input: synchronous accumulator clear, driven by the
//     controller during SCAN so every run starts from zero.
//     (It shares the reset gating, so it costs no extra area.)

module pe #(
  parameter DATA_WIDTH = 4,
  parameter ACC_WIDTH  = 10
)
(
  input  logic clk,
  input  logic rst,
  input  logic clear,
  input  logic [DATA_WIDTH-1:0] a_in,
  input  logic [DATA_WIDTH-1:0] b_in,
  output logic [DATA_WIDTH-1:0] a_out,
  output logic [DATA_WIDTH-1:0] b_out,
  output logic [ACC_WIDTH-1:0]  mac_out
);

  always_ff @(posedge clk) begin
    a_out <= a_in;
    b_out <= b_in;
    if (rst | clear)
      mac_out <= '0;
    else
      mac_out <= mac_out + (a_in * b_in);
  end

endmodule
