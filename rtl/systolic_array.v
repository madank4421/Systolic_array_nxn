// systolic_array.v
// Unchanged from your original version - included here only so the
// full module set is self-contained. All the sparsity/skip logic lives
// in the controller and the PE; the array's structure doesn't need to
// change because the controller now simply streams a *shorter,
// compacted* sequence into the same fixed spatial grid.

`include "pe.v"

module systolic_array
  #(parameter ARRAY_SIZE = 4,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = (2 * DATA_WIDTH) + $clog2(ARRAY_SIZE))
  (
    input  logic [DATA_WIDTH-1:0] row_input [0:ARRAY_SIZE-1],
    input  logic [DATA_WIDTH-1:0] col_input [0:ARRAY_SIZE-1],
    input  logic clk,
    input  logic rst,

    output logic [ACC_WIDTH-1:0] result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1]
  );

  logic [DATA_WIDTH-1:0] a_pipe [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] b_pipe [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  genvar i, j;

  generate
    for (i = 0; i < ARRAY_SIZE; i++) begin : row
      for (j = 0; j < ARRAY_SIZE; j++) begin : column

        pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
        pe_inst (
          .a_in    ((j == 0) ? row_input[i]   : a_pipe[i][j-1]),
          .b_in    ((i == 0) ? col_input[j]   : b_pipe[i-1][j]),
          .clk     (clk),
          .rst     (rst),
          .a_out   (a_pipe[i][j]),
          .b_out   (b_pipe[i][j]),
          .mac_out (result_matrix[i][j])
        );

      end : column
    end : row
  endgenerate

endmodule
