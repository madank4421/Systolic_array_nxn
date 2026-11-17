module chip_top (
    input  clk_pad, rst_pad, sclk_pad, cs_n_pad, mosi_pad,
    output miso_pad, irq_pad, busy_pad
);
    wire clk_c, rst_c, sclk_c, cs_n_c, mosi_c;
    wire miso_c, irq_c, busy_c;

    // input pads (PAD = bond pad side, C = into the core)
    IPAD20 u_clk  (.IN1(clk_pad),  .OUT1(clk_c));
    IPAD3U u_rst  (.IN1(rst_pad),  .OUT1(rst_c));
    IPAD3D u_sclk (.IN1(sclk_pad), .OUT1(sclk_c));
    IPAD3U u_csn  (.IN1(cs_n_pad), .OUT1(cs_n_c));
    IPAD30 u_mosi (.IN1(mosi_pad), .OUT1(mosi_c));

    // output pads (I = from the core, PAD = bond pad side)
    PAD_OPAD04 u_miso (.IN1(miso_c), .PAD(miso_pad));
    PAD_OPAD02 u_irq  (.IN1(irq_c),  .PAD(irq_pad));
    PAD_OPAD02 u_busy (.IN1(busy_c), .PAD(busy_pad));

    systolic_chip_top core (
        .clk(clk_c), .rst(rst_c), .sclk(sclk_c), .cs_n(cs_n_c), .mosi(mosi_c),
        .miso(miso_c), .irq(irq_c), .busy(busy_c)
    );
endmodule
