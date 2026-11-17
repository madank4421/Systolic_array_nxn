// spi_slave.v
//
// SPI slave, mode 0 (CPOL=0, CPHA=0), MSB first, byte-oriented.
//
// Everything runs in the core 'clk' domain. sclk / cs_n / mosi are treated
// as asynchronous inputs: each goes through a 2-flop synchronizer, and sclk
// edges are detected from a 3rd flop. sclk is never used as a clock, so
// synthesis, CTS and STA stay single-clock.
//
// REQUIREMENT: clk >= 8 x sclk (recommended). Below ~6x, MISO cannot settle
// before the master samples it.
//
// Behaviour
//   - Bits are sampled on the (synchronized) rising edge of sclk.
//   - MISO is updated on the (synchronized) falling edge of sclk.
//   - When a full byte has been received, rx_valid pulses for one clk cycle
//     and rx_byte holds the byte.
//   - At the falling edge that begins each byte (bit_cnt == 0), tx_data is
//     latched and shifted out MSB first. The reg bank must therefore keep
//     tx_data valid from shortly after rx_valid until the next falling edge
//     (half an sclk period later).
//   - When cs_n is high, all state is cleared and miso is driven to 0,
//     so an aborted transaction can never leave the slave out of sync.
//   - The master should hold cs_n low for at least half an sclk period after
//     the last rising sclk edge (normal SPI practice).

module spi_slave (
    input  wire       clk,
    input  wire       rst,        // synchronous, active high

    // physical SPI pins
    input  wire       sclk,
    input  wire       cs_n,
    input  wire       mosi,
    output reg        miso,

    // byte-level interface to the register bank
    output wire       cs_active,  // 1 while chip-select is asserted
    output reg        rx_valid,   // 1-cycle pulse: rx_byte is new
    output reg  [7:0] rx_byte,
    input  wire [7:0] tx_data     // byte to shift out for the next byte slot
);

    // ---- synchronizers -------------------------------------------------
    reg [2:0] sclk_ff;
    reg [1:0] cs_ff;
    reg [1:0] mosi_ff;

    always @(posedge clk) begin
        if (rst) begin
            sclk_ff <= 3'b000;
            cs_ff   <= 2'b11;
            mosi_ff <= 2'b00;
        end else begin
            sclk_ff <= {sclk_ff[1:0], sclk};
            cs_ff   <= {cs_ff[0],     cs_n};
            mosi_ff <= {mosi_ff[0],   mosi};
        end
    end

    wire sclk_rise = ( sclk_ff[1] & ~sclk_ff[2]);
    wire sclk_fall = (~sclk_ff[1] &  sclk_ff[2]);
    assign cs_active = ~cs_ff[1];

    // ---- shift engine --------------------------------------------------
    reg [7:0] rx_shift;
    reg [7:0] tx_shift;
    reg [2:0] bit_cnt;     // bits received so far in the current byte (0..7)

    always @(posedge clk) begin
        if (rst || !cs_active) begin
            bit_cnt  <= 3'd0;
            rx_shift <= 8'h00;
            tx_shift <= 8'h00;
            rx_byte  <= 8'h00;
            rx_valid <= 1'b0;
            miso     <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            if (sclk_rise) begin
                rx_shift <= {rx_shift[6:0], mosi_ff[1]};
                bit_cnt  <= bit_cnt + 3'd1;          // wraps 7 -> 0
                if (bit_cnt == 3'd7) begin
                    rx_byte  <= {rx_shift[6:0], mosi_ff[1]};
                    rx_valid <= 1'b1;
                end
            end

            if (sclk_fall) begin
                if (bit_cnt == 3'd0) begin
                    // start of a new byte slot: load and present MSB
                    miso     <= tx_data[7];
                    tx_shift <= {tx_data[6:0], 1'b0};
                end else begin
                    miso     <= tx_shift[7];
                    tx_shift <= {tx_shift[6:0], 1'b0};
                end
            end
        end
    end

endmodule
