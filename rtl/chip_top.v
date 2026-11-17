module chip_top (
    input  clk_pad, rst_pad, sclk_pad, cs_n_pad, mosi_pad,
    output miso_pad, irq_pad, busy_pad
);
    wire clk_c, rst_c, sclk_c, cs_n_c, mosi_c;
    wire miso_c, irq_c, busy_c;

    // input pads (PAD = bond pad side, C = into the core)
    PADIN u_clk  (.PAD(clk_pad),  .C(clk_c));
    PADIN u_rst  (.PAD(rst_pad),  .C(rst_c));
    PADIN u_sclk (.PAD(sclk_pad), .C(sclk_c));
    PADIN u_csn  (.PAD(cs_n_pad), .C(cs_n_c));
    PADIN u_mosi (.PAD(mosi_pad), .C(mosi_c));

    // output pads (I = from the core, PAD = bond pad side)
    PADOUT u_miso (.I(miso_c), .PAD(miso_pad));
    PADOUT u_irq  (.I(irq_c),  .PAD(irq_pad));
    PADOUT u_busy (.I(busy_c), .PAD(busy_pad));

    systolic_chip_top core (
        .clk(clk_c), .rst(rst_c), .sclk(sclk_c), .cs_n(cs_n_c), .mosi(mosi_c),
        .miso(miso_c), .irq(irq_c), .busy(busy_c)
    );
endmodule
