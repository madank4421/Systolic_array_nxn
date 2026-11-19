module chip_top (
    input  wire clk,
    input  wire rst,
    input  wire cs_n,
    input  wire sclk,
    input  wire mosi,
    output wire miso_to_pad,   // goes to OPAD04 input in the frame
    output wire irq_to_pad,    // goes to OPAD02 input in the frame
    output wire busy_to_pad    // goes to OPAD02 input in the frame
);

    wire miso_core, irq_core, busy_core;

    // your design
    spi_core u_core (
        .clk(clk), .rst(rst), .cs_n(cs_n), .sclk(sclk), .mosi(mosi),
        .miso(miso_core), .irq(irq_core), .busy(busy_core)
    );

    // pad drivers
    INVR02 u_drv_miso (.IN1(miso_core), .OUT1(miso_to_pad));   // for OPAD04
    INVR01 u_drv_irq  (.IN1(irq_core),  .OUT1(irq_to_pad));    // for OPAD02
    INVR01 u_drv_busy (.IN1(busy_core), .OUT1(busy_to_pad));   // for OPAD02

endmodule
