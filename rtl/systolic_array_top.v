// systolic_array_top.v
// External ports unchanged. Internally, the controller's acc_clear output is
// wired to the array's clear input.

`include "systolic_array_controller.v"
`include "systolic_array.v"

module systolic_array_top #(
  parameter ARRAY_SIZE = 4,
  parameter DATA_WIDTH = 4,
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

  output logic [$clog2(ARRAY_SIZE + 1)-1:0] nnz_k_count,
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] skipped_k_count
);

  logic [DATA_WIDTH-1:0] row_stream [0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] col_stream [0:ARRAY_SIZE-1];
  logic acc_clear;

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
    .row_stream      (row_stream),
    .col_stream      (col_stream),
    .acc_clear       (acc_clear),
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
    .clear         (acc_clear),
    .result_matrix (result_matrix)
  );

endmodule
