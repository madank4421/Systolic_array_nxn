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
    input  logic clear,

    output logic [ACC_WIDTH-1:0] result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1]
  );

  logic [DATA_WIDTH-1:0] a_pipe [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] b_pipe [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  genvar i, j;

  generate
    for (i = 0; i < ARRAY_SIZE; i++) begin : row
      for (j = 0; j < ARRAY_SIZE; j++) begin : column

        logic [DATA_WIDTH-1:0] a_in_w, b_in_w;

        if (j == 0) begin : a_edge
          assign a_in_w = row_input[i];
        end else begin : a_int
          assign a_in_w = a_pipe[i][j-1];
        end

        if (i == 0) begin : b_edge
          assign b_in_w = col_input[j];
        end else begin : b_int
          assign b_in_w = b_pipe[i-1][j];
        end

        pe #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
        pe_inst (
          .a_in    (a_in_w),
          .b_in    (b_in_w),
          .clk     (clk),
          .rst     (rst),
          .clear   (clear),
          .a_out   (a_pipe[i][j]),
          .b_out   (b_pipe[i][j]),
          .mac_out (result_matrix[i][j])
        );

      end : column
    end : row
  endgenerate

endmodule
