// systolic_array_top.v
// Same structure as your original top; just forwards the two new
// debug/reporting outputs from the controller so a testbench can log
// how many k-slices were skipped per run.

`include "systolic_array_controller.v"
`include "systolic_array.v"

module systolic_array_top #(
  parameter ARRAY_SIZE = 4,
  parameter DATA_WIDTH = 8,
  parameter ACC_WIDTH  = (2 * DATA_WIDTH) + $clog2(ARRAY_SIZE)
)(
  input  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
  input  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
  input  logic start,
  input  logic clk,
  input  logic rst,
  input  logic [2:0] active_size,
  output logic busy,
  output logic done,
  output logic [ACC_WIDTH-1:0] result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],

  // Sparsity reporting: read these after `done` goes high to log how
  // much streaming work was skipped for that particular input pair.
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] nnz_k_count,
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] skipped_k_count
);

  logic [DATA_WIDTH-1:0] row_stream [0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] col_stream [0:ARRAY_SIZE-1];
    logic pe_clear;

  systolic_array_controller #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .DATA_WIDTH(DATA_WIDTH)
  ) controller_inst (
    .matrix_a        (matrix_a),
    .matrix_b        (matrix_b),
    .active_size     (active_size),
    .start           (start),
    .clk             (clk),
    .rst             (rst),
    .busy            (busy),
    .done            (done),
        .pe_clear        (pe_clear),
    .row_stream      (row_stream),
    .col_stream      (col_stream),
    .nnz_k_count     (nnz_k_count),
    .skipped_k_count (skipped_k_count)
  );

  systolic_array #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH(ACC_WIDTH)
  ) systolic_array_inst (
    .row_input     (row_stream),
    .col_input     (col_stream),
    .clk           (clk),
    .rst           (rst),
        .clear         (pe_clear),
    .result_matrix (result_matrix)
  );

endmodule
