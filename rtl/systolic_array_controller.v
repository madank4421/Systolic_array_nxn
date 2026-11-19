// systolic_array_controller.v
//
// SCAN state builds a compacted list of the contraction-dimension (k) indices
// that actually contribute to the result. A k-slice is skippable if column k
// of matrix_a is all zero OR row k of matrix_b is all zero.
//
// LOAD length is (active_size + nnz_k - 2) and FLUSH ends at
// (2*active_size + nnz_k - 3). With nnz_k = active_size this reduces to the
// dense schedule.
//
// Change vs. previous version: new output acc_clear, high during SCAN, which
// clears every PE accumulator before the run starts. Without it a second run
// would accumulate on top of the first result. If all k-slices are skipped,
// the (cleared) accumulators read back as zero.
// The old commented-out duplicate of this file has been removed.

module systolic_array_controller #(
  parameter ARRAY_SIZE = 4,
  parameter DATA_WIDTH = 4
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
  output logic acc_clear,

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
  logic [CNT_WIDTH-1:0] nnz_k;
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
          // If every k-slice is skippable the product is structurally zero.
          next_state = (nnz_k_next == 0) ? DONE : LOAD;
      end
      LOAD: begin
        if (cycle_count == (active_size + nnz_k - 2))
          next_state = FLUSH;
      end
      FLUSH: begin
        if (cycle_count == ((2 * active_size) + nnz_k - 3))
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

  assign busy      = (curr_state != IDLE);
  assign done      = (curr_state == DONE);
  assign acc_clear = (curr_state == SCAN);

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

  // cycle_count drives LOAD/FLUSH sequencing
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
  // Streaming logic: row i is offset by i cycles; the value sent at each
  // local step comes from the compacted nzk_list.
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
