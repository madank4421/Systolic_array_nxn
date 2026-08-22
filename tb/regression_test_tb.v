
// Regression test
`include "systolic_array_top.sv"

module tb;

  parameter ARRAY_SIZE = 4;
  parameter DATA_WIDTH = 8;
  parameter ACC_WIDTH  = (2*DATA_WIDTH);

  logic clk;
  logic rst;
  logic start;
  logic [2:0] active_size;

  logic busy;
  logic done;

  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  logic [ACC_WIDTH-1:0] result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [ACC_WIDTH-1:0] exp_result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  integer i, j;
  integer error_count;

  systolic_array_top #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH(ACC_WIDTH)
  ) dut (
    .matrix_a(matrix_a),
    .matrix_b(matrix_b),
    .active_size(active_size),
    .start(start),
    .clk(clk),
    .rst(rst),
    .busy(busy),
    .done(done),
    .result_matrix(result_matrix)
  );

  always #5 clk = ~clk;

  initial begin

    clk = 0;
    rst = 1;
    start = 0;
    active_size = 4;

    #20;
    rst = 0;
    @(posedge clk);

    $display("==================================================");
    $display(" LAST ROW / LAST COLUMN SPARSE REGRESSION TEST ");
    $display("==================================================");

    // Clear matrices
    for(i = 0; i < ARRAY_SIZE; i = i + 1)
      for(j = 0; j < ARRAY_SIZE; j = j + 1) begin
        matrix_a[i][j] = 0;
        matrix_b[i][j] = 0;
      end

    // Only one surviving MAC at k = 2
    matrix_a[3][2] = 7;
    matrix_b[2][3] = 9;

    $display("--- Matrix A ---");
    for(i = 0; i < ARRAY_SIZE; i++)
      $display("%p", matrix_a[i]);

    $display("--- Matrix B ---");
    for(i = 0; i < ARRAY_SIZE; i++)
      $display("%p", matrix_b[i]);

    @(posedge clk);
    rst = 1;
    @(posedge clk);
    rst = 0;

    @(posedge clk);
    start = 1;
    @(posedge clk);
    start = 0;

    @(posedge done);
    @(posedge clk);

    // Expected result
    for(i = 0; i < ARRAY_SIZE; i = i + 1)
      for(j = 0; j < ARRAY_SIZE; j = j + 1)
        exp_result_matrix[i][j] = 0;

    exp_result_matrix[3][3] = 7 * 9;

    $display("--- Hardware Result ---");
    for(i = 0; i < ARRAY_SIZE; i++)
      $display("%p", result_matrix[i]);

    $display("--- Expected Result ---");
    for(i = 0; i < ARRAY_SIZE; i++)
      $display("%p", exp_result_matrix[i]);

    error_count = 0;

    for(i = 0; i < ARRAY_SIZE; i = i + 1)
      for(j = 0; j < ARRAY_SIZE; j = j + 1)
        if(result_matrix[i][j] !== exp_result_matrix[i][j]) begin
          $display("ERROR [%0d][%0d]: HW=%0d Expected=%0d",
                   i, j,
                   result_matrix[i][j],
                   exp_result_matrix[i][j]);
          error_count = error_count + 1;
        end

    if(error_count == 0)
      $display(">>> REGRESSION TEST PASSED <<<");
    else
      $display(">>> REGRESSION TEST FAILED (%0d ERRORS) <<<", error_count);

    $finish;

  end

endmodule

/*
`include "systolic_array_top.sv"

module tb;

  parameter ARRAY_SIZE = 4;
  parameter DATA_WIDTH = 8;
  parameter ACC_WIDTH  = (2 * DATA_WIDTH);

  logic clk;
  logic rst;
  logic start;
  logic [2:0] active_size;

  logic busy;
  logic done;

  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  logic [ACC_WIDTH-1:0] result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [ACC_WIDTH-1:0] exp_result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  integer i;
  integer j;
  integer k;
  integer test_num;
  integer error_count;
  integer zero_count_a;
  integer zero_count_b;

  systolic_array_top #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH(ACC_WIDTH)
  ) dut (
    .matrix_a(matrix_a),
    .matrix_b(matrix_b),
    .active_size(active_size),
    .start(start),
    .clk(clk),
    .rst(rst),
    .busy(busy),
    .done(done),
    .result_matrix(result_matrix)
  );

  always #5 clk = ~clk;


  task generate_sparse_matrices(input integer size);

    begin

      zero_count_a = 0;
      zero_count_b = 0;

      for(i = 0; i < ARRAY_SIZE; i = i + 1) begin
        for(j = 0; j < ARRAY_SIZE; j = j + 1) begin

          if((i < size) && (j < size)) begin

            if($urandom_range(0, 99) < 50) begin
              matrix_a[i][j] = 0;
              zero_count_a = zero_count_a + 1;
            end
            else begin
              matrix_a[i][j] = $urandom_range(1, 20);
            end

            if($urandom_range(0, 99) < 50) begin
              matrix_b[i][j] = 0;
              zero_count_b = zero_count_b + 1;
            end
            else begin
              matrix_b[i][j] = $urandom_range(1, 20);
            end

          end
          else begin
            matrix_a[i][j] = 0;
            matrix_b[i][j] = 0;
          end

        end
      end

    end

  endtask


  task calculate_expected(input integer size);

    begin

      for(i = 0; i < ARRAY_SIZE; i = i + 1) begin
        for(j = 0; j < ARRAY_SIZE; j = j + 1) begin

          exp_result_matrix[i][j] = 0;

          if((i < size) && (j < size)) begin

            for(k = 0; k < size; k = k + 1) begin

              exp_result_matrix[i][j] =
                exp_result_matrix[i][j] +
                (matrix_a[i][k] * matrix_b[k][j]);

            end

          end

        end
      end

    end

  endtask


  task compare_results;

    begin

      error_count = 0;

      for(i = 0; i < ARRAY_SIZE; i = i + 1) begin
        for(j = 0; j < ARRAY_SIZE; j = j + 1) begin

          if(result_matrix[i][j] !== exp_result_matrix[i][j]) begin

            $display(
              "ERROR [%0d][%0d]: Hardware = %0d, Expected = %0d",
              i,
              j,
              result_matrix[i][j],
              exp_result_matrix[i][j]
            );

            error_count = error_count + 1;

          end

        end
      end

    end

  endtask


  initial begin

    clk = 0;
    rst = 1;
    start = 0;
    active_size = 0;

    #20;
    rst = 0;

    @(posedge clk);


    for(active_size = 2; active_size <= 4; active_size = active_size + 1) begin

      for(test_num = 1; test_num <= 3; test_num = test_num + 1) begin

        $display("");
        $display("==================================================");
        $display("       TEST %0d : %0dx%0d SPARSE CONFIGURATION",
                 test_num, active_size, active_size);
        $display("==================================================");

        generate_sparse_matrices(active_size);

        $display("Zeros in Matrix A = %0d", zero_count_a);
        $display("Zeros in Matrix B = %0d", zero_count_b);
        $display("size of matrix = %d x %d", active_size, active_size);
        
        $display("");
        $display("--- Matrix A ---");

        for(i = 0; i < active_size; i = i + 1)
          $display("%p", matrix_a[i]);

        $display("");
        $display("--- Matrix B ---");

        for(i = 0; i < active_size; i = i + 1)
          $display("%p", matrix_b[i]);


        @(posedge clk);
        rst = 1;

        @(posedge clk);
        rst = 0;

        @(posedge clk);
        start = 1;

        @(posedge clk);
        start = 0;

        @(posedge done);
        @(posedge clk);


        calculate_expected(active_size);


        $display("");
        $display("--- Hardware Result ---");

        for(i = 0; i < active_size; i = i + 1)
          $display("%p", result_matrix[i]);


        $display("");
        $display("--- Expected Result ---");

        for(i = 0; i < active_size; i = i + 1)
          $display("%p", exp_result_matrix[i]);


        compare_results();


        if(error_count == 0) begin
          $display("");
          $display(">>> TEST PASSED <<<");
        end
        else begin
          $display("");
          $display(">>> TEST FAILED: %0d ERROR(S) <<<", error_count);
        end

      end

    end


    $display("");
    $display("==================================================");
    $display("          ALL 9 SPARSE TESTS COMPLETED           ");
    $display("==================================================");

    $finish;

  end

endmodule

/*
`include "systolic_array_top.sv"

module tb;

  parameter ARRAY_SIZE = 4;
  parameter DATA_WIDTH = 8;
  parameter ACC_WIDTH  = (2 * DATA_WIDTH);

  logic clk;
  logic rst;
  logic start;
  logic [2:0] active_size;

  logic busy;
  logic done;

  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  logic [ACC_WIDTH-1:0] result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [ACC_WIDTH-1:0] exp_result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  integer i;
  integer j;
  integer k;
  integer test_num;
  integer error_count;

  systolic_array_top #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH(ACC_WIDTH)
  ) dut (
    .matrix_a(matrix_a),
    .matrix_b(matrix_b),
    .active_size(active_size),
    .start(start),
    .clk(clk),
    .rst(rst),
    .busy(busy),
    .done(done),
    .result_matrix(result_matrix)
  );

  always #5 clk = ~clk;

  initial begin
    clk = 0;
    rst = 1;
    start = 0;
    active_size = 0;

    #20;
    rst = 0;

    @(posedge clk);

    for(active_size = 2; active_size <= 4; active_size = active_size + 1) begin

      for(test_num = 1; test_num <= 3; test_num = test_num + 1) begin

        $display("");
        $display("==================================================");
        $display("       TEST %0d : %0dx%0d CONFIGURATION",
                 test_num, active_size, active_size);
        $display("==================================================");

        for(i = 0; i < ARRAY_SIZE; i = i + 1) begin
          for(j = 0; j < ARRAY_SIZE; j = j + 1) begin
            matrix_a[i][j] = $urandom_range(1, 20);
            matrix_b[i][j] = $urandom_range(1, 20);
          end
        end

       // $display("--- Matrix A ---");
       // for(i = 0; i < active_size; i = i + 1)
       //  $display("%p", matrix_a[i]);

        //$display("--- Matrix B ---");
        //for(i = 0; i < active_size; i = i + 1)
        //  $display("%p", matrix_b[i]);

        @(posedge clk);
        rst = 1;

        @(posedge clk);
        rst = 0;

        @(posedge clk);
        start = 1;

        @(posedge clk);
        start = 0;

        @(posedge done);
        @(posedge clk);

        for(i = 0; i < ARRAY_SIZE; i = i + 1) begin
          for(j = 0; j < ARRAY_SIZE; j = j + 1) begin

            exp_result_matrix[i][j] = 0;

            if((i < active_size) && (j < active_size)) begin

              for(k = 0; k < active_size; k = k + 1) begin
                exp_result_matrix[i][j] =
                  exp_result_matrix[i][j] +
                  (matrix_a[i][k] * matrix_b[k][j]);
              end

            end

          end
        end

        //$display("--- Hardware Result ---");
        //for(i = 0; i < active_size; i = i + 1)
        //  $display("%p", result_matrix[i]);

        //$display("--- Expected Result ---");
        //for(i = 0; i < active_size; i = i + 1)
        //  $display("%p", exp_result_matrix[i]);

        error_count = 0;

        for(i = 0; i < ARRAY_SIZE; i = i + 1) begin
          for(j = 0; j < ARRAY_SIZE; j = j + 1) begin

            if(result_matrix[i][j] !== exp_result_matrix[i][j]) begin

              $display(
                "ERROR [%0d][%0d]: Hardware = %0d, Expected = %0d",
                i,
                j,
                result_matrix[i][j],
                exp_result_matrix[i][j]
              );

              error_count = error_count + 1;

            end

          end
        end

        if(error_count == 0)
          $display(">>> TEST PASSED <<<");
        else
          $display(">>> TEST FAILED: %0d ERROR(S) <<<", error_count);

      end

    end

    $display("");
    $display("==================================================");
    $display("             ALL 9 TESTS COMPLETED               ");
    $display("==================================================");

    $finish;
  end

endmodule
*/
