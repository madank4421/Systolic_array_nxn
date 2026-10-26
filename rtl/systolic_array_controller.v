// systolic_array_controller.v
//
// Adds a SCAN state that runs before LOAD. SCAN inspects matrix_a and
// matrix_b (for the currently active_size sub-block) and builds a
// compacted list of only the contraction-dimension (k) indices that
// actually contribute to the result:
//
//   a k-slice is SKIPPABLE if EITHER
//     - column k of matrix_a is entirely zero (A[:,k] == 0), OR
//     - row k of matrix_b is entirely zero    (B[k,:] == 0)
//   because C[i][j] += A[i][k] * B[k][j] for every i,j at that k -
//   if either side is all-zero, that whole diagonal wavefront step
//   contributes nothing to any output element.
//
// LOAD/FLUSH then run for a length based on nnz_k (number of
// *useful* k's), not active_size - so structural sparsity in the
// contraction dimension directly shortens the streaming schedule,
// not just PE-level switching power. This is what gives you a real,
// measurable cycle-count reduction to report (nnz_k_count vs
// active_size), in addition to the power savings from PE operand
// isolation.
//
// Correctness note: the compacted sequence preserves the *relative*
// per-row/per-column skew (row i still starts i cycles after row 0,
// exactly as before) - only the *content* of what's streamed at each
// local time-step changes (it pulls from the compacted k-list instead
// of the raw index). Skipped k's contribute zero anyway, so the final
// accumulated dot product is identical to the dense/original schedule.
//
// Timing note (important): LOAD must run long enough for BOTH
//   - the compacted data length (nnz_k), and
//   - the physical skew of the last row/column (active_size - 1),
// so the bound is (active_size + nnz_k - 2), NOT (2*nnz_k - 2). Using
// nnz_k alone ends LOAD too early whenever nnz_k < active_size,
// silently dropping the last k-slice(s) for later rows/columns.
// Setting nnz_k = active_size recovers the original dense formulas
// (2*active_size-2 for LOAD, 3*active_size-3 for FLUSH) exactly.

module systolic_array_controller #(
  parameter ARRAY_SIZE = 4,
  parameter DATA_WIDTH = 8
)(
  input  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
  input  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
  input  logic [2:0] active_size,
  input  logic start,
  input  logic clk,
  input  logic rst,
  output logic busy,
  output logic done,
  output logic pe_clear,
  output logic [DATA_WIDTH-1:0] row_stream [0:ARRAY_SIZE-1],
  output logic [DATA_WIDTH-1:0] col_stream [0:ARRAY_SIZE-1],

  // Debug / reporting outputs - not needed for functionality, but very
  // useful for your report: e.g. "on a 4x4 matrix with 1 zero k-slice,
  // nnz_k_count = 3, skipped_k_count = 1 -> ~25% fewer streaming cycles".
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] nnz_k_count,
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] skipped_k_count
);

  localparam int CNT_WIDTH     = $clog2(ARRAY_SIZE + 1);
  localparam int COUNTER_WIDTH = $clog2(3 * ARRAY_SIZE + 1);

  typedef enum logic [2:0] {IDLE, SCAN, LOAD, FLUSH, DONE} state_t;
  state_t curr_state, next_state;

  logic [COUNTER_WIDTH-1:0] cycle_count;
  logic [2:0] scan_idx;                    // k being scanned: 0..active_size-1
  logic [2:0] nzk_list [0:ARRAY_SIZE-1];   // compacted list of useful k indices
  logic [CNT_WIDTH-1:0] nnz_k;             // final count, latched after SCAN
  logic [CNT_WIDTH-1:0] nnz_k_next;

  logic col_a_all_zero, row_b_all_zero, skip_k;
  integer p;

  // ---------------------------------------------------------------
  // Per-k sparsity check (combinational, one k per SCAN cycle)
  // ---------------------------------------------------------------
  always_comb begin
    col_a_all_zero = 1'b1;
    row_b_all_zero = 1'b1;
    for (p = 0; p < ARRAY_SIZE; p = p + 1) begin
      if (p < active_size) begin
        if (matrix_a[p][scan_idx] != '0) col_a_all_zero = 1'b0;
        if (matrix_b[scan_idx][p] != '0) row_b_all_zero = 1'b0;
      end
    end
    skip_k = col_a_all_zero || row_b_all_zero;
  end

  // ---------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst)
      curr_state <= IDLE;
    else
      curr_state <= next_state;
  end

  always_comb begin
    next_state = curr_state;
    case (curr_state)
      IDLE: begin
        if (start)
          next_state = SCAN;
      end
      SCAN: begin
        if (scan_idx == (active_size - 1))
          // If every k-slice turned out to be skippable, the whole
          // product is structurally zero - skip straight to DONE.
          next_state = (nnz_k_next == 0) ? DONE : LOAD;
      end
      LOAD: begin
        // The last physical row still needs (active_size-1) cycles of
        // skew, even though only nnz_k data values are actually sent.
        // Using nnz_k alone here (as an earlier version of this file
        // did) ends LOAD too early and drops the last k-slice(s) for
        // the later rows/columns whenever nnz_k < active_size.
        if (cycle_count == (active_size + nnz_k - 2))
          next_state = FLUSH;
      end
      FLUSH: begin
        if (cycle_count >= ((2 * active_size) + nnz_k - 3))
          next_state = DONE;
      end
      DONE: begin
        next_state = IDLE;
      end
      default: begin
        next_state = IDLE;
      end
    endcase
  end

  assign busy = (curr_state != IDLE);
  assign done = (curr_state == DONE);
  assign pe_clear = (curr_state == SCAN);

  // scan_idx: walks k = 0 .. active_size-1 during SCAN
  always_ff @(posedge clk) begin
    if (rst)
      scan_idx <= '0;
    else if (curr_state == SCAN)
      scan_idx <= scan_idx + 1'b1;
    else
      scan_idx <= '0;
  end

  // Build the compacted non-skippable-k index list while scanning
  assign nnz_k_next = skip_k ? nnz_k : (nnz_k + 1'b1);

  always_ff @(posedge clk) begin
    if (rst) begin
      nnz_k <= '0;
    end
    else if (curr_state == SCAN) begin
      if (!skip_k)
        nzk_list[nnz_k] <= scan_idx;
      nnz_k <= nnz_k_next;
    end
    else if (curr_state == IDLE) begin
      nnz_k <= '0;   // ready for the next run
    end
    // else: hold value (LOAD/FLUSH/DONE need the final nnz_k unchanged)
  end

  // cycle_count drives LOAD/FLUSH sequencing, now based on nnz_k
  always_ff @(posedge clk) begin
    if (rst)
      cycle_count <= '0;
    else if ((curr_state == LOAD) || (curr_state == FLUSH))
      cycle_count <= cycle_count + 1'b1;
    else
      cycle_count <= '0;
  end

  // Reporting: latch the final counts once SCAN finishes
  always_ff @(posedge clk) begin
    if (rst) begin
      nnz_k_count     <= '0;
      skipped_k_count <= '0;
    end
    else if ((curr_state == SCAN) && (next_state != SCAN)) begin
      nnz_k_count     <= nnz_k_next;
      skipped_k_count <= active_size - nnz_k_next;
    end
  end

  // ---------------------------------------------------------------
  // Streaming logic: same skew structure as before (row i still
  // offset by i cycles), but the value sent at each local step comes
  // from the compacted nzk_list instead of the raw cycle-derived k.
  // ---------------------------------------------------------------
  integer i;
  logic signed [COUNTER_WIDTH:0] m;   // local (compacted) sequence position
  logic [2:0] k_val;

  always_comb begin
    for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
      row_stream[i] = '0;
      col_stream[i] = '0;
    end
    if (curr_state == LOAD) begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
        m = cycle_count - i;
        if (i < active_size) begin
          if ((m >= 0) && (m < nnz_k)) begin
            k_val = nzk_list[m];
            row_stream[i] = matrix_a[i][k_val];
            col_stream[i] = matrix_b[k_val][i];
          end
        end
      end
    end
  end

endmodule

/*
// systolic_array_controller.v
//
// Adds a SCAN state that runs before LOAD. SCAN inspects matrix_a and
// matrix_b (for the currently active_size sub-block) and builds a
// compacted list of only the contraction-dimension (k) indices that
// actually contribute to the result:
//
//   a k-slice is SKIPPABLE if EITHER
//     - column k of matrix_a is entirely zero (A[:,k] == 0), OR
//     - row k of matrix_b is entirely zero    (B[k,:] == 0)
//   because C[i][j] += A[i][k] * B[k][j] for every i,j at that k -
//   if either side is all-zero, that whole diagonal wavefront step
//   contributes nothing to any output element.
//
// LOAD/FLUSH then run for a length based on nnz_k (number of
// *useful* k's), not active_size - so structural sparsity in the
// contraction dimension directly shortens the streaming schedule,
// not just PE-level switching power. This is what gives you a real,
// measurable cycle-count reduction to report (nnz_k_count vs
// active_size), in addition to the power savings from PE operand
// isolation.
//
// Correctness note: the compacted sequence preserves the *relative*
// per-row/per-column skew (row i still starts i cycles after row 0,
// exactly as before) - only the *content* of what's streamed at each
// local time-step changes (it pulls from the compacted k-list instead
// of the raw index). Skipped k's contribute zero anyway, so the final
// accumulated dot product is identical to the dense/original schedule.

module systolic_array_controller #(
  parameter ARRAY_SIZE = 4,
  parameter DATA_WIDTH = 8
)(
  input  logic [DATA_WIDTH-1:0] matrix_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
  input  logic [DATA_WIDTH-1:0] matrix_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
  input  logic [2:0] active_size,
  input  logic start,
  input  logic clk,
  input  logic rst,
  output logic busy,
  output logic done,
  output logic [DATA_WIDTH-1:0] row_stream [0:ARRAY_SIZE-1],
  output logic [DATA_WIDTH-1:0] col_stream [0:ARRAY_SIZE-1],

  // Debug / reporting outputs - not needed for functionality, but very
  // useful for your report: e.g. "on a 4x4 matrix with 1 zero k-slice,
  // nnz_k_count = 3, skipped_k_count = 1 -> ~25% fewer streaming cycles".
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] nnz_k_count,
  output logic [$clog2(ARRAY_SIZE + 1)-1:0] skipped_k_count
);

  localparam int CNT_WIDTH     = $clog2(ARRAY_SIZE + 1);
  localparam int COUNTER_WIDTH = $clog2(3 * ARRAY_SIZE + 1);

  typedef enum logic [2:0] {IDLE, SCAN, LOAD, FLUSH, DONE} state_t;
  state_t curr_state, next_state;

  logic [COUNTER_WIDTH-1:0] cycle_count;
  logic [2:0] scan_idx;                    // k being scanned: 0..active_size-1
  logic [2:0] nzk_list [0:ARRAY_SIZE-1];   // compacted list of useful k indices
  logic [CNT_WIDTH-1:0] nnz_k;             // final count, latched after SCAN
  logic [CNT_WIDTH-1:0] nnz_k_next;

  logic col_a_all_zero, row_b_all_zero, skip_k;
  integer p;

  // ---------------------------------------------------------------
  // Per-k sparsity check (combinational, one k per SCAN cycle)
  // ---------------------------------------------------------------
  always_comb begin
    col_a_all_zero = 1'b1;
    row_b_all_zero = 1'b1;
    for (p = 0; p < ARRAY_SIZE; p = p + 1) begin
      if (p < active_size) begin
        if (matrix_a[p][scan_idx] != '0) col_a_all_zero = 1'b0;
        if (matrix_b[scan_idx][p] != '0) row_b_all_zero = 1'b0;
      end
    end
    skip_k = col_a_all_zero || row_b_all_zero;
  end

  // ---------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst)
      curr_state <= IDLE;
    else
      curr_state <= next_state;
  end

  always_comb begin
    next_state = curr_state;
    case (curr_state)
      IDLE: begin
        if (start)
          next_state = SCAN;
      end
      SCAN: begin
        if (scan_idx == (active_size - 1))
          // If every k-slice turned out to be skippable, the whole
          // product is structurally zero - skip straight to DONE.
          next_state = (nnz_k_next == 0) ? DONE : LOAD;
      end
      LOAD: begin
        if (cycle_count == ((2 * nnz_k) - 2))
          next_state = FLUSH;
      end
      FLUSH: begin
        if (cycle_count == ((3 * nnz_k) - 3))
          next_state = DONE;
      end
      DONE: begin
        next_state = IDLE;
      end
      default: begin
        next_state = IDLE;
      end
    endcase
  end

  assign busy = (curr_state != IDLE);
  assign done = (curr_state == DONE);

  // scan_idx: walks k = 0 .. active_size-1 during SCAN
  always_ff @(posedge clk) begin
    if (rst)
      scan_idx <= '0;
    else if (curr_state == SCAN)
      scan_idx <= scan_idx + 1'b1;
    else
      scan_idx <= '0;
  end

  // Build the compacted non-skippable-k index list while scanning
  assign nnz_k_next = skip_k ? nnz_k : (nnz_k + 1'b1);

  always_ff @(posedge clk) begin
    if (rst) begin
      nnz_k <= '0;
    end
    else if (curr_state == SCAN) begin
      if (!skip_k)
        nzk_list[nnz_k] <= scan_idx;
      nnz_k <= nnz_k_next;
    end
    else if (curr_state == IDLE) begin
      nnz_k <= '0;   // ready for the next run
    end
    // else: hold value (LOAD/FLUSH/DONE need the final nnz_k unchanged)
  end

  // cycle_count drives LOAD/FLUSH sequencing, now based on nnz_k
  always_ff @(posedge clk) begin
    if (rst)
      cycle_count <= '0;
    else if ((curr_state == LOAD) || (curr_state == FLUSH))
      cycle_count <= cycle_count + 1'b1;
    else
      cycle_count <= '0;
  end

  // Reporting: latch the final counts once SCAN finishes
  always_ff @(posedge clk) begin
    if (rst) begin
      nnz_k_count     <= '0;
      skipped_k_count <= '0;
    end
    else if ((curr_state == SCAN) && (next_state != SCAN)) begin
      nnz_k_count     <= nnz_k_next;
      skipped_k_count <= active_size - nnz_k_next;
    end
  end

  // ---------------------------------------------------------------
  // Streaming logic: same skew structure as before (row i still
  // offset by i cycles), but the value sent at each local step comes
  // from the compacted nzk_list instead of the raw cycle-derived k.
  // ---------------------------------------------------------------
  integer i;
  logic signed [COUNTER_WIDTH:0] m;   // local (compacted) sequence position
  logic [2:0] k_val;

  always_comb begin
    for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
      row_stream[i] = '0;
      col_stream[i] = '0;
    end
    if (curr_state == LOAD) begin
      for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
        m = cycle_count - i;
        if (i < active_size) begin
          if ((m >= 0) && (m < nnz_k)) begin
            k_val = nzk_list[m];
            row_stream[i] = matrix_a[i][k_val];
            col_stream[i] = matrix_b[k_val][i];
          end
        end
      end
    end
  end

endmodule
*/
