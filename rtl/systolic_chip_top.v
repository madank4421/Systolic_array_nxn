// systolic_chip_top.v
//
// Chip-level wrapper: SPI slave + register bank around systolic_array_top.
// Only 8 signal pins.
//
//   clk   : core clock (must be >= 8x sclk)
//   rst   : external reset, active high. Asserted asynchronously, released
//           synchronously to clk.
//   sclk, cs_n, mosi, miso : SPI mode 0
//   irq   : high when a run has completed (sticky, cleared by next start)
//   busy  : high while a run is in progress
//
// Change vs. previous version: DATA_WIDTH is now 4 (ACC_WIDTH = 10).
// spi_slave.v is unchanged.

`include "spi_slave.v"
`include "reg_bank.v"
`include "systolic_array_top.v"

module systolic_chip_top (
    input  wire clk,
    input  wire rst,
    input  wire sclk,
    input  wire cs_n,
    input  wire mosi,
    output wire miso,
    output wire irq,
    output wire busy
);
    localparam ARRAY_SIZE = 4;
    localparam DATA_WIDTH = 4;
    localparam ACC_WIDTH  = (2 * DATA_WIDTH) + 2;
    localparam CNT_W      = 3;      // $clog2(ARRAY_SIZE+1)

    // ---- reset synchronizer: async assert, sync deassert ---------------
    reg [1:0] rst_ff;
    always @(posedge clk or posedge rst) begin
        if (rst) rst_ff <= 2'b11;
        else     rst_ff <= {rst_ff[0], 1'b0};
    end
    wire rst_int = rst_ff[1];

    // ---- SPI slave <-> register bank -----------------------------------
    wire       cs_active;
    wire       rx_valid;
    wire [7:0] rx_byte;
    wire [7:0] tx_data;

    spi_slave u_spi (
        .clk       (clk),
        .rst       (rst_int),
        .sclk      (sclk),
        .cs_n      (cs_n),
        .mosi      (mosi),
        .miso      (miso),
        .cs_active (cs_active),
        .rx_valid  (rx_valid),
        .rx_byte   (rx_byte),
        .tx_data   (tx_data)
    );

    // ---- register bank <-> core ----------------------------------------
    wire [ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH-1:0] matrix_a;
    wire [ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH-1:0] matrix_b;
    wire [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0]  result_matrix;
    wire [2:0]       active_size;
    wire             start;
    wire             core_busy;
    wire             core_done;
    wire [CNT_W-1:0] nnz_k_count;
    wire [CNT_W-1:0] skipped_k_count;

    reg_bank #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .CNT_W      (CNT_W)
    ) u_regs (
        .clk             (clk),
        .rst             (rst_int),
        .cs_active       (cs_active),
        .rx_valid        (rx_valid),
        .rx_byte         (rx_byte),
        .tx_data         (tx_data),
        .matrix_a        (matrix_a),
        .matrix_b        (matrix_b),
        .active_size     (active_size),
        .start           (start),
        .core_busy       (core_busy),
        .core_done       (core_done),
        .nnz_k_count     (nnz_k_count),
        .skipped_k_count (skipped_k_count),
        .result_matrix   (result_matrix),
        .busy_out        (busy),
        .irq             (irq)
    );

    systolic_array_top #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_core (
        .matrix_a        (matrix_a),
        .matrix_b        (matrix_b),
        .start           (start),
        .clk             (clk),
        .rst             (rst_int),
        .active_size     (active_size),
        .busy            (core_busy),
        .done            (core_done),
        .result_matrix   (result_matrix),
        .nnz_k_count     (nnz_k_count),
        .skipped_k_count (skipped_k_count)
    );

endmodule
