// =============================================================================
// systolic_array_tb.sv
//
// Self-checking testbench for systolic_array_top (sparse-k systolic array).
//
// What it checks
//   1. Functional: result_matrix == golden A*B for the active_size sub-block,
//      and every PE outside the block is exactly 0.
//   2. Sparsity reporting: nnz_k_count / skipped_k_count match a golden
//      model of the "skippable k-slice" rule (A[:,k]==0 or B[k,:]==0,
//      evaluated only over the active_size sub-block).
//   3. Schedule: start->done latency matches the expected FSM schedule
//      (SCAN + LOAD + FLUSH), so a regression in the LOAD/FLUSH bounds is
//      caught even if the numeric result happens to survive.
//   4. Protocol: done is a single-cycle pulse, done implies busy, busy drops
//      after done, outputs are never X after reset, results hold after done.
//   5. Robustness: back-to-back runs with NO reset in between (accumulator
//      clear), reset in the middle of a run, start pulses while busy,
//      garbage data outside the active sub-block, watchdog on hangs.
//
// Stimulus
//   - Directed tests (identity, all-zero A/B, mismatched sparsity, max values,
//     single non-zero, sub-block zero detection, ...)
//   - Exhaustive sweep of every k-skip pattern for every active_size, both
//     "zero column of A" and "zero row of B" variants
//   - Constrained-random regression (sizes, densities, value ranges, gaps)
//
// Run (Icarus Verilog):
//   iverilog -g2012 -o sim systolic_array_tb.sv && vvp sim
//   vvp sim +seed=123 +dump          (optional: seed / VCD dump)
//
// NOTE: this file `include`s systolic_array_top.v, which in turn includes
//       the controller, array and PE. Do NOT also pass those files on the
//       command line.
// Assumes ARRAY_SIZE == 4 (directed tests use k indices 0..3).
// =============================================================================
`timescale 1ns/1ps
`include "systolic_array_top.v"

module systolic_array_tb;

  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  localparam integer ARRAY_SIZE     = 4;
  localparam integer DATA_WIDTH     = 8;
  localparam integer ACC_WIDTH      = (2 * DATA_WIDTH) + $clog2(ARRAY_SIZE);
  localparam integer CNT_W          = $clog2(ARRAY_SIZE + 1);
  localparam integer CLK_PERIOD     = 10;
  localparam integer TIMEOUT_CYCLES = (8 * ARRAY_SIZE) + 16;
  localparam integer NUM_RANDOM     = 500;

  // --------------------------------------------------------------------------
  // DUT signals
  // --------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic                  clk;
  logic                  rst;
  logic                  start;
  logic [2:0]            active_size;
  logic                  busy;
  logic                  done;
  logic [ACC_WIDTH-1:0]  result_matrix [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  logic [CNT_W-1:0]      nnz_k_count;
  logic [CNT_W-1:0]      skipped_k_count;

  systolic_array_top #(
    .ARRAY_SIZE (ARRAY_SIZE),
    .DATA_WIDTH (DATA_WIDTH)
  ) dut (
    .matrix_a        (matrix_a),
    .matrix_b        (matrix_b),
    .start           (start),
    .clk             (clk),
    .rst             (rst),
    .active_size     (active_size),
    .busy            (busy),
    .done            (done),
    .result_matrix   (result_matrix),
    .nnz_k_count     (nnz_k_count),
    .skipped_k_count (skipped_k_count)
  );

  // --------------------------------------------------------------------------
  // Clock
  // --------------------------------------------------------------------------
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Bookkeeping
  // --------------------------------------------------------------------------
  integer errors;
  integer test_count;
  integer idle_gap;
  reg     verbose;
  integer seed_arg;
  integer tot_cycles;
  integer tot_dense_cycles;
  integer cov_size [0:ARRAY_SIZE];
  integer cov_nnz  [0:ARRAY_SIZE];

  // Golden model results
  integer exp_c [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
  integer exp_nnz;

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------
  function integer rnd(input integer m);
    begin
      rnd = $urandom % m;
    end
  endfunction

  // Expected cycles from the clock edge that samples `start` until the first
  // cycle in which `done` is observed high (edge-count after the start edge).
  //   SCAN  : n cycles
  //   LOAD  : n + nnz - 1 cycles
  //   FLUSH : n - 1 cycles (minimum 1)
  //   nnz==0: SCAN -> DONE directly
  function integer exp_latency(input integer n, input integer nz);
    integer l, f;
    begin
      if (nz == 0) begin
        exp_latency = n;
      end else begin
        l = n + nz - 1;
        f = (n > 1) ? (n - 1) : 1;
        exp_latency = n + l + f;
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  // Golden model
  // --------------------------------------------------------------------------
  task compute_golden(input integer n);
    integer i, j, k, ta, tb;
    reg col_nz, row_nz;
    begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1)
          exp_c[i][j] = 0;

      exp_nnz = 0;
      for (k = 0; k < n; k = k + 1) begin
        col_nz = 1'b0;
        row_nz = 1'b0;
        for (i = 0; i < n; i = i + 1) begin
          if (matrix_a[i][k] != 0) col_nz = 1'b1;
          if (matrix_b[k][i] != 0) row_nz = 1'b1;
        end
        if (col_nz && row_nz) exp_nnz = exp_nnz + 1;
      end

      for (i = 0; i < n; i = i + 1)
        for (j = 0; j < n; j = j + 1)
          for (k = 0; k < n; k = k + 1) begin
            ta = matrix_a[i][k];
            tb = matrix_b[k][j];
            exp_c[i][j] = exp_c[i][j] + (ta * tb);
          end
    end
  endtask

  // --------------------------------------------------------------------------
  // Matrix construction helpers
  // --------------------------------------------------------------------------
  task clear_a;
    integer i, j;
    begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1)
          matrix_a[i][j] = '0;
    end
  endtask

  task clear_b;
    integer i, j;
    begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1)
          matrix_b[i][j] = '0;
    end
  endtask

  // mode 0: 1..255   mode 1: 1..3 (small)   mode 2: always 255 (max)
  // dens = percentage of elements that are non-zero
  function [DATA_WIDTH-1:0] rnd_val(input integer dens, input integer mode);
    begin
      if (rnd(100) < dens) begin
        case (mode)
          1:       rnd_val = 1 + rnd(3);
          2:       rnd_val = 8'hFF;
          default: rnd_val = 1 + rnd(255);
        endcase
      end else begin
        rnd_val = '0;
      end
    end
  endfunction

  task fill_a(input integer dens, input integer mode);
    integer i, j;
    begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1)
          matrix_a[i][j] = rnd_val(dens, mode);
    end
  endtask

  task fill_b(input integer dens, input integer mode);
    integer i, j;
    begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1)
        for (j = 0; j < ARRAY_SIZE; j = j + 1)
          matrix_b[i][j] = rnd_val(dens, mode);
    end
  endtask

  task zero_a_col(input integer k);
    integer i;
    begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1) matrix_a[i][k] = '0;
    end
  endtask

  task zero_b_row(input integer k);
    integer j;
    begin
      for (j = 0; j < ARRAY_SIZE; j = j + 1) matrix_b[k][j] = '0;
    end
  endtask

  // --------------------------------------------------------------------------
  // Reporting
  // --------------------------------------------------------------------------
  task report_error(input string msg);
    begin
      errors = errors + 1;
      $display("[%0t] ERROR: %s", $time, msg);
    end
  endtask

  task dump_matrices(input integer n);
    integer i, j;
    begin
      //$display("    A (active %0d)                B");
      $display("    A (active)                B");
      for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
        $write("    ");
        for (j = 0; j < ARRAY_SIZE; j = j + 1) $write("%4d", matrix_a[i][j]);
        $write("      ");
        for (j = 0; j < ARRAY_SIZE; j = j + 1) $write("%4d", matrix_b[i][j]);
        $write("\n");
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // Reset
  // --------------------------------------------------------------------------
  task do_reset;
    begin
      @(negedge clk);
      rst   = 1'b1;
      start = 1'b0;
      repeat (3) @(negedge clk);
      rst = 1'b0;
      @(negedge clk);
    end
  endtask

  // --------------------------------------------------------------------------
  // Run control
  // --------------------------------------------------------------------------
  // Pulse start for exactly one clock edge.
  task launch(input integer n);
    begin
      @(negedge clk);
      active_size = n[2:0];
      start       = 1'b1;
      @(negedge clk);
      start       = 1'b0;
    end
  endtask

  // Count clock edges (after the start edge) until done is high.
  task wait_done(output integer cyc, output reg timed_out);
    begin
      cyc       = 0;
      timed_out = 1'b0;
      while (!done && !timed_out) begin
        @(posedge clk);
        #1;
        cyc = cyc + 1;
        if (cyc > TIMEOUT_CYCLES) timed_out = 1'b1;
      end
    end
  endtask

  // Compare everything against the golden model.
  task check_results(input string  name,
                     input integer n,
                     input integer cyc,
                     input reg     timed_out,
                     input reg     check_latency);
    integer i, j, e0;
    reg [ACC_WIDTH-1:0] exp_v;
    reg [ACC_WIDTH-1:0] snap [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    begin
      e0 = errors;
      test_count = test_count + 1;

      if (timed_out) begin
        report_error($sformatf("%s: TIMEOUT - done never asserted (n=%0d)", name, n));
        dump_matrices(n);
        do_reset;   // recover so later tests can still run
      end else begin
        // ---- protocol while done is high
        if (busy !== 1'b1)
          report_error($sformatf("%s: done asserted but busy is %b", name, busy));

        // ---- latency / schedule
        if (check_latency && (cyc != exp_latency(n, exp_nnz)))
          report_error($sformatf("%s: latency %0d cycles, expected %0d (n=%0d nnz=%0d)",
                                 name, cyc, exp_latency(n, exp_nnz), n, exp_nnz));

        // ---- sparsity counters
        if (nnz_k_count !== exp_nnz[CNT_W-1:0])
          report_error($sformatf("%s: nnz_k_count=%0d expected %0d",
                                 name, nnz_k_count, exp_nnz));
        if (skipped_k_count !== (n - exp_nnz))
          report_error($sformatf("%s: skipped_k_count=%0d expected %0d",
                                 name, skipped_k_count, n - exp_nnz));

        // ---- results (whole array, so out-of-block PEs must be 0)
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
          for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
            exp_v     = exp_c[i][j];
            snap[i][j] = result_matrix[i][j];
            if (result_matrix[i][j] !== exp_v)
              report_error($sformatf("%s: C[%0d][%0d]=%0d expected %0d",
                                     name, i, j, result_matrix[i][j], exp_v));
          end

        // ---- one cycle later: done must have dropped, busy must be low,
        //      and results must hold.
        @(posedge clk);
        #1;
        if (done !== 1'b0)
          report_error($sformatf("%s: done stayed high for more than 1 cycle", name));
        if (busy !== 1'b0)
          report_error($sformatf("%s: busy still high after done", name));
        for (i = 0; i < ARRAY_SIZE; i = i + 1)
          for (j = 0; j < ARRAY_SIZE; j = j + 1)
            if (result_matrix[i][j] !== snap[i][j])
              report_error($sformatf("%s: C[%0d][%0d] changed after done", name, i, j));

        // ---- statistics
        tot_cycles       = tot_cycles + cyc;
        tot_dense_cycles = tot_dense_cycles + exp_latency(n, n);
        cov_size[n]      = cov_size[n] + 1;
        cov_nnz[exp_nnz] = cov_nnz[exp_nnz] + 1;
      end

      if (errors != e0) begin
        $display("[FAIL] %s", name);
        dump_matrices(n);
      end else if (verbose) begin
        $display("[PASS] %-34s n=%0d nnz=%0d cycles=%0d", name, n, exp_nnz, cyc);
      end
    end
  endtask

  // Full single test: golden -> launch -> wait -> check -> idle gap.
  task run_test(input string name, input integer n);
    integer cyc;
    reg     to;
    begin
      compute_golden(n);
      launch(n);
      wait_done(cyc, to);
      check_results(name, n, cyc, to, 1'b1);
      repeat (idle_gap) @(negedge clk);
    end
  endtask

  // --------------------------------------------------------------------------
  // Passive protocol monitors (run for the whole simulation)
  // --------------------------------------------------------------------------
  reg prev_done;
  reg prev_busy;
  reg prev_start;
  reg monitors_en;

  initial begin
    prev_done   = 1'b0;
    prev_busy   = 1'b0;
    prev_start  = 1'b0;
    monitors_en = 1'b0;
  end

  always @(posedge clk) begin
    if (monitors_en && !rst) begin
      if ((^{busy, done}) === 1'bx)
        report_error("busy/done is X/Z outside of reset");
      if (done === 1'b1 && prev_done === 1'b1)
        report_error("monitor: done high on two consecutive cycles");
      if (done === 1'b1 && busy !== 1'b1)
        report_error("monitor: done without busy");
      if (!start && !prev_start && !prev_busy && busy === 1'b1 && !prev_done)
        report_error("monitor: busy rose without a start pulse");
    end
    prev_done <= (done === 1'b1) && !rst;
    prev_busy <= (busy === 1'b1) && !rst;
    prev_start <= start;
  end

  // --------------------------------------------------------------------------
  // Global watchdog
  // --------------------------------------------------------------------------
  initial begin
    #100_000_000;
    $display("[%0t] FATAL: global simulation watchdog expired", $time);
    $finish;
  end

  // --------------------------------------------------------------------------
  // Main
  // --------------------------------------------------------------------------
  integer n, t, k, mask, variant, kk, cyc_m;
  reg     to_m;
  integer dens_a, dens_b, vmode, zero_kind;
  integer dens_tab [0:4];
  reg [8*24-1:0] nm;

  initial begin
    errors           = 0;
    test_count       = 0;
    idle_gap         = 0;
    verbose          = 1'b1;
    tot_cycles       = 0;
    tot_dense_cycles = 0;
    for (t = 0; t <= ARRAY_SIZE; t = t + 1) begin
      cov_size[t] = 0;
      cov_nnz[t]  = 0;
    end
    dens_tab[0] = 0;  dens_tab[1] = 25;  dens_tab[2] = 50;
    dens_tab[3] = 75; dens_tab[4] = 100;

    if (ARRAY_SIZE < 4) begin
      $display("FATAL: directed tests require ARRAY_SIZE >= 4");
      $finish;
    end

    if ($value$plusargs("seed=%d", seed_arg)) begin
      t = $urandom(seed_arg);
      $display("Using seed %0d", seed_arg);
    end
    if ($test$plusargs("dump")) begin
      $dumpfile("systolic_array_tb.vcd");
      $dumpvars(0, systolic_array_tb);
    end

    // init inputs
    rst         = 1'b0;
    start       = 1'b0;
    active_size = 3'd4;
    clear_a;
    clear_b;

    do_reset;
    monitors_en = 1'b1;

    // ---- post-reset state
    if (busy !== 1'b0 || done !== 1'b0)
      report_error("busy/done not low after reset");
    for (t = 0; t < ARRAY_SIZE*ARRAY_SIZE; t = t + 1)
      if (result_matrix[t / ARRAY_SIZE][t % ARRAY_SIZE] !== '0)
        report_error("result_matrix not zero after reset");

    $display("\n================ DIRECTED TESTS ================");

    // 1. dense random
    fill_a(100, 0); fill_b(100, 0);
    run_test("dense_random", 4);

    // 2. identity * B == B
    clear_a;
    for (t = 0; t < ARRAY_SIZE; t = t + 1) matrix_a[t][t] = 1;
    fill_b(100, 0);
    run_test("identity_times_B", 4);

    // 3. all-zero A (nnz=0 shortcut). Previous run left a non-zero result,
    //    so this also proves the accumulators are cleared.
    clear_a; fill_b(100, 0);
    run_test("zero_A_after_dense", 4);

    // 4. all-zero B
    fill_a(100, 0); clear_b;
    run_test("zero_B", 4);

    // 5. one zero column of A
    fill_a(100, 0); fill_b(100, 0); zero_a_col(1);
    run_test("zero_A_col1", 4);

    // 6. one zero row of B
    fill_a(100, 0); fill_b(100, 0); zero_b_row(2);
    run_test("zero_B_row2", 4);

    // 7. zero A col 0 AND zero B row 3 (two different k skipped)
    fill_a(100, 0); fill_b(100, 0); zero_a_col(0); zero_b_row(3);
    run_test("zero_Acol0_Brow3", 4);

    // 8. only k=3 contributes
    clear_a; clear_b;
    for (t = 0; t < ARRAY_SIZE; t = t + 1) begin
      matrix_a[t][3] = 1 + rnd(255);
      matrix_b[3][t] = 1 + rnd(255);
    end
    run_test("only_k3_contributes", 4);

    // 9. mismatched sparsity: A non-zero only in cols 0,1; B non-zero only
    //    in rows 2,3 -> inputs are non-trivial but product is structurally 0
    clear_a; clear_b;
    for (t = 0; t < ARRAY_SIZE; t = t + 1) begin
      matrix_a[t][0] = 1 + rnd(255);  matrix_a[t][1] = 1 + rnd(255);
      matrix_b[2][t] = 1 + rnd(255);  matrix_b[3][t] = 1 + rnd(255);
    end
    run_test("mismatched_sparsity_nnz0", 4);

    // 10. max values: 4 * 255 * 255 = 260100 must fit in ACC_WIDTH
    fill_a(100, 2); fill_b(100, 2);
    run_test("max_values_255", 4);

    // 11. garbage outside the active sub-block must be ignored
    fill_a(100, 0); fill_b(100, 0);
    run_test("active3_garbage_outside", 3);
    run_test("active2_garbage_outside", 2);
    run_test("active1_garbage_outside", 1);

    // 12. zero detection is limited to the active sub-block:
    //     for n=2, A[0..1][1]==0 but A[2][1] != 0 -> k=1 must still be skipped
    fill_a(100, 0); fill_b(100, 0);
    matrix_a[0][1] = 0; matrix_a[1][1] = 0; matrix_a[2][1] = 9; matrix_a[3][1] = 9;
    run_test("subblock_zero_col_n2", 2);

    // 13. single non-zero element pair
    clear_a; clear_b;
    matrix_a[2][1] = 7; matrix_b[1][3] = 9;
    run_test("single_nonzero_pair", 4);

    // 14. back-to-back identical runs, no reset, no gap
    fill_a(100, 0); fill_b(100, 0);
    run_test("b2b_identical_run1", 4);
    run_test("b2b_identical_run2", 4);
    run_test("b2b_identical_run3", 4);

    // 15. start pulses while busy must be ignored
    fill_a(100, 0); fill_b(100, 0);
    compute_golden(4);
    launch(4);
    repeat (2) @(negedge clk);
    start = 1'b1; @(negedge clk); start = 1'b0;     // during SCAN
    repeat (3) @(negedge clk);
    start = 1'b1; @(negedge clk); start = 1'b0;     // during LOAD
    wait_done(cyc_m, to_m);
    check_results("start_ignored_while_busy", 4, cyc_m, to_m, 1'b0);

    // 16. reset in the middle of a run, then a clean run
    fill_a(100, 0); fill_b(100, 0);
    launch(4);
    repeat (5) @(negedge clk);
    if (busy !== 1'b1) report_error("mid_reset: DUT not busy before reset");
    do_reset;
    if (busy !== 1'b0 || done !== 1'b0)
      report_error("mid_reset: busy/done not low after reset");
    run_test("run_after_mid_run_reset", 4);

    // 17. exhaustive k-skip patterns for every active size.
    //     variant 0: skip via zero column of A; variant 1: skip via zero row of B.
    $display("\n========= EXHAUSTIVE k-SKIP PATTERNS =========");
    verbose = 1'b0;
    for (n = 1; n <= ARRAY_SIZE; n = n + 1)
      for (variant = 0; variant < 2; variant = variant + 1)
        for (mask = 0; mask < (1 << n); mask = mask + 1) begin
          fill_a(100, 0); fill_b(100, 0);
          for (kk = 0; kk < n; kk = kk + 1)
            if (mask[kk]) begin
              if (variant == 0) zero_a_col(kk);
              else              zero_b_row(kk);
            end
          run_test($sformatf("skip_n%0d_v%0d_mask%0d", n, variant, mask), n);
        end
    $display("exhaustive sweep done (%0d tests so far)", test_count);

    // 18. constrained-random regression
    $display("\n============ RANDOM REGRESSION ============");
    for (t = 0; t < NUM_RANDOM; t = t + 1) begin
      n      = 1 + rnd(ARRAY_SIZE);
      dens_a = dens_tab[rnd(5)];
      dens_b = dens_tab[rnd(5)];
      vmode  = rnd(3);
      fill_a(dens_a, vmode);
      fill_b(dens_b, vmode);

      // sometimes force structured k-skips on top of the random density
      zero_kind = rnd(4);
      if (zero_kind == 1) zero_a_col(rnd(ARRAY_SIZE));
      if (zero_kind == 2) zero_b_row(rnd(ARRAY_SIZE));
      if (zero_kind == 3) begin
        zero_a_col(rnd(ARRAY_SIZE));
        zero_b_row(rnd(ARRAY_SIZE));
      end

      idle_gap = rnd(4);   // 0..3 idle cycles between runs (0 = immediate restart)
      run_test($sformatf("random_%0d", t), n);
    end
    idle_gap = 0;

    // ---- coverage / performance summary
    $display("\n================= SUMMARY =================");
    $display("tests run                : %0d", test_count);
    for (t = 1; t <= ARRAY_SIZE; t = t + 1)
      $display("coverage active_size=%0d  : %0d runs", t, cov_size[t]);
    for (t = 0; t <= ARRAY_SIZE; t = t + 1)
      $display("coverage nnz_k=%0d        : %0d runs", t, cov_nnz[t]);
    if (tot_dense_cycles > 0)
      $display("start->done cycles       : %0d actual vs %0d dense (%0d%% reduction)",
               tot_cycles, tot_dense_cycles,
               ((tot_dense_cycles - tot_cycles) * 100) / tot_dense_cycles);

    if (errors == 0)
      $display("\n*** ALL TESTS PASSED (%0d tests) ***\n", test_count);
    else
      $display("\n*** TEST FAILED: %0d error(s) in %0d tests ***\n", errors, test_count);

    $finish;
  end

endmodule
