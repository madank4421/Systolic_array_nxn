// reg_bank.v
//
// Register bank between the SPI slave and systolic_array_top.
// Written for ARRAY_SIZE=4 and DATA_WIDTH < 8 (default 4); the address map
// assumes 16 elements per matrix.
//
// SPI protocol (mode 0, one transaction per cs_n low):
//   byte 0      : {rw, addr[6:0]}   rw=1 -> write, rw=0 -> read
//   byte 1..n   : data, address auto-increments after every byte
//   (for reads, the master sends dummy bytes and samples MISO)
//
// Address map
//   0x00-0x0F  matrix_a, row-major, A[i][k] at 0x00 + i*4 + k   (R/W)
//   0x10-0x1F  matrix_b, row-major, B[k][j] at 0x10 + k*4 + j   (R/W)
//              One element per byte. Only the low DATA_WIDTH bits are
//              stored; on read the upper bits return 0.
//   0x20       CTRL   W: bit0 = start (self-clearing pulse)
//                        bits3:1 = active_size (accepted only if 1..4)
//                     R: {4'b0, active_size, 1'b0}
//   0x21       STATUS (R) bit0 = busy
//                         bit1 = done (sticky, cleared by start)
//                         bits4:2 = nnz_k_count
//                         bits7:5 = skipped_k_count
//   0x22       ID     (R) 0x5A   (link sanity check)
//   0x40-0x7F  result_matrix (R). Element e = i*4+j is at 0x40 + 4*e:
//                +0 = bits[7:0], +1 = bits[15:8] (zero-extended), +2 = 0, +3 = 0
//              With DATA_WIDTH=4 the result is 10 bits: +0 = bits[7:0],
//              +1 = {6'b0, bits[9:8]}.
//
// Rules
//   - Writes to A, B and CTRL are ignored while the core is busy.
//   - Result and nnz/skipped values are only meaningful when STATUS.done=1
//     and busy=0. The accumulators are cleared at the start of every run.
//   - Writes to read-only addresses are ignored.
//   - a_reg / b_reg have NO reset (saves area): contents are undefined until
//     written. Write every element you will use (with active_size < 4 only
//     the top-left active_size x active_size block is read) before start.

module reg_bank #(
    parameter ARRAY_SIZE = 4,
    parameter DATA_WIDTH = 4,
    parameter ACC_WIDTH  = (2 * DATA_WIDTH) + 2,
    parameter CNT_W      = 3      // $clog2(ARRAY_SIZE+1)
)(
    input  wire        clk,
    input  wire        rst,

    // from spi_slave
    input  wire        cs_active,
    input  wire        rx_valid,
    input  wire [7:0]  rx_byte,
    output reg  [7:0]  tx_data,

    // to systolic_array_top
    output wire [ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH-1:0] matrix_a,
    output wire [ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH-1:0] matrix_b,
    output wire [2:0]  active_size,
    output wire        start,

    // from systolic_array_top
    input  wire        core_busy,
    input  wire        core_done,
    input  wire [CNT_W-1:0] nnz_k_count,
    input  wire [CNT_W-1:0] skipped_k_count,
    input  wire [ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH-1:0] result_matrix,

    // to chip pins
    output wire        busy_out,
    output wire        irq
);

    localparam [7:0] ID_VALUE = 8'h5A;
    localparam [2:0] SIZE_RST = ARRAY_SIZE;   // power-up active_size

    // ---- state ---------------------------------------------------------
    reg [ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH-1:0] a_reg;   // no reset
    reg [ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH-1:0] b_reg;   // no reset
    reg [2:0] size_reg;
    reg       start_pulse;
    reg       done_sticky;

    reg       have_addr;   // address byte of the current transaction received
    reg       is_write;
    reg [6:0] addr;

    assign matrix_a    = a_reg;
    assign matrix_b    = b_reg;
    assign active_size = size_reg;
    assign start       = start_pulse;
    assign irq         = done_sticky;

    // Busy as seen by the host: covers the 1-cycle gap between the start
    // pulse and the controller raising busy.
    wire busy_s = core_busy | start_pulse;
    assign busy_out = busy_s;

    wire wr_ok = is_write & ~busy_s;
    wire [2:0] new_size = rx_byte[3:1];

    // ---- control path (reset) -----------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            size_reg    <= SIZE_RST;
            start_pulse <= 1'b0;
            done_sticky <= 1'b0;
            have_addr   <= 1'b0;
            is_write    <= 1'b0;
            addr        <= 7'h00;
        end else begin
            start_pulse <= 1'b0;

            if (core_done)
                done_sticky <= 1'b1;

            if (!cs_active) begin
                have_addr <= 1'b0;
            end else if (rx_valid) begin
                if (!have_addr) begin
                    have_addr <= 1'b1;
                    is_write  <= rx_byte[7];
                    addr      <= rx_byte[6:0];
                end else begin
                    addr <= addr + 7'd1;

                    if (wr_ok) begin
                        if (addr == 7'h20) begin
                            if (new_size >= 3'd1 && new_size <= ARRAY_SIZE)
                                size_reg <= new_size;
                            if (rx_byte[0]) begin
                                start_pulse <= 1'b1;
                                done_sticky <= 1'b0;
                            end
                        end
                    end
                end
            end
        end
    end

    // ---- A / B storage (no reset) --------------------------------------
    always @(posedge clk) begin
        if (!rst && cs_active && rx_valid && have_addr && wr_ok
            && (addr[6:5] == 2'b00)) begin
            if (!addr[4])
                a_reg[addr[3:0]*DATA_WIDTH +: DATA_WIDTH] <= rx_byte[DATA_WIDTH-1:0];
            else
                b_reg[addr[3:0]*DATA_WIDTH +: DATA_WIDTH] <= rx_byte[DATA_WIDTH-1:0];
        end
    end

    // ---- read path (combinational on the current address pointer) ------
    reg [31:0] elem;
    reg [3:0]  elem_idx;

    always @* begin
        tx_data  = 8'h00;
        elem     = 32'h0;
        elem_idx = addr[5:2];

        if (addr[6]) begin
            // result window: 4 bytes per element (zero-extended)
            elem = result_matrix[elem_idx*ACC_WIDTH +: ACC_WIDTH];
            case (addr[1:0])
                2'd0:    tx_data = elem[7:0];
                2'd1:    tx_data = elem[15:8];
                2'd2:    tx_data = elem[23:16];
                default: tx_data = elem[31:24];
            endcase
        end else if (!addr[5]) begin
            // A / B windows, zero-extended to a byte
            if (!addr[4])
                tx_data = {{(8-DATA_WIDTH){1'b0}}, a_reg[addr[3:0]*DATA_WIDTH +: DATA_WIDTH]};
            else
                tx_data = {{(8-DATA_WIDTH){1'b0}}, b_reg[addr[3:0]*DATA_WIDTH +: DATA_WIDTH]};
        end else begin
            // 0x20-0x3F: control / status / id
            case (addr[4:0])
                5'h00:   tx_data = {4'b0000, size_reg, 1'b0};
                5'h01:   tx_data = {skipped_k_count, nnz_k_count, done_sticky, busy_s};
                5'h02:   tx_data = ID_VALUE;
                default: tx_data = 8'h00;
            endcase
        end
    end

endmodule
