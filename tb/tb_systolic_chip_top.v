// tb_systolic_chip_top.v
//
// Self-checking testbench. Acts as an SPI master (mode 0), loads A and B,
// starts the run, polls STATUS, reads back the result and nnz/skipped
// counts, and compares against a software reference.
//
// Added over the first version
//   1) Random sub-cycle skew (0 .. one clk period) on sclk, cs_n and mosi, so
//      the synchronizers see every phase relationship. Configurable ratio.
//   2) Write-while-busy guard test (busy is forced inside the DUT, because a
//      real run is always shorter than one SPI byte at a legal sclk rate).
//   3) Back-to-back runs WITHOUT reloading A/B (also proves the accumulators
//      are cleared between runs).
//
// Command-line configuration (macros):
//   +define+SCLK_HALF=<ns>   sclk half period, default 50
//   +define+CLK_HALF=<ns>    clk half period,  default 5   (clk = 100 MHz)
//   +define+NO_JITTER        disable the random skew
//
//   clk/sclk = SCLK_HALF/CLK_HALF.   Defaults give 10x.
//     SCLK_HALF=50   -> 10x  (10 MHz sclk)   default
//     SCLK_HALF=40   ->  8x  (12.5 MHz sclk) minimum supported ratio
//     SCLK_HALF=500  -> 100x ( 1 MHz sclk)
//
// Icarus:  iverilog -g2005 -DSCLK_HALF=40 -o sim tb_systolic_chip_top.v && vvp sim
// VCS:     vcs -sverilog -full64 +define+SCLK_HALF=40 tb_systolic_chip_top.v

`timescale 1ns/1ps
`include "systolic_chip_top.v"

`ifndef CLK_HALF
  `define CLK_HALF 5
`endif
`ifndef SCLK_HALF
  `define SCLK_HALF 50
`endif

module tb_systolic_chip_top;

    localparam CLK_HALF  = `CLK_HALF;
    localparam SCLK_HALF = `SCLK_HALF;
`ifdef NO_JITTER
    localparam JITTER_EN = 0;
`else
    localparam JITTER_EN = 1;
`endif
    // random skew spans one full clk period, covering every sampling phase
    localparam real JIT_MAX = (2.0 * CLK_HALF) - 0.1;

    reg  clk = 1'b0;
    reg  rst = 1'b1;
    reg  sclk = 1'b0;
    reg  cs_n = 1'b1;
    reg  mosi = 1'b0;
    wire miso, irq, busy;

    systolic_chip_top dut (
        .clk(clk), .rst(rst),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .irq(irq), .busy(busy)
    );

    always #CLK_HALF clk = ~clk;

    // ---- test data / bookkeeping ---------------------------------------
    reg [7:0] A [0:15];
    reg [7:0] B [0:15];
    reg [7:0] rxb [0:63];
    integer   expc [0:15];

    integer seed;
    integer errors;
    integer total_checks;
    integer last_size;       // active_size most recently started
    reg [7:0] dummy;
    reg [7:0] tmp;
    reg [7:0] st;

    // ---- random sub-cycle skew -----------------------------------------
    task jit;
        integer r;
        real    d;
        begin
            if (JITTER_EN) begin
                r = $random(seed) & 32'h7FFF_FFFF;
                r = r % 100;
                d = r * JIT_MAX / 100.0;
                #(d);
            end
        end
    endtask

    // ---- SPI master primitives -----------------------------------------
    task spi_byte;
        input  [7:0] tx;
        output [7:0] rx;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                jit;
                mosi = tx[i];
                #(SCLK_HALF);
                jit;
                sclk = 1'b1;
                rx[i] = miso;          // sample on rising edge
                #(SCLK_HALF);
                jit;
                sclk = 1'b0;
            end
        end
    endtask

    task spi_begin;
        begin
            jit;
            cs_n = 1'b0;
            #(SCLK_HALF);
        end
    endtask

    task spi_end;
        begin
            #(SCLK_HALF);
            jit;
            cs_n = 1'b1;
            mosi = 1'b0;
            #(2*SCLK_HALF);
        end
    endtask

    task spi_wr1;
        input [6:0] a;
        input [7:0] d;
        begin
            spi_begin;
            spi_byte({1'b1, a}, dummy);
            spi_byte(d, dummy);
            spi_end;
        end
    endtask

    task spi_rd1;
        input  [6:0] a;
        output [7:0] d;
        reg    [7:0] r;
        begin
            spi_begin;
            spi_byte({1'b0, a}, dummy);
            spi_byte(8'h00, r);
            spi_end;
            d = r;
        end
    endtask

    // ---- checking helpers ----------------------------------------------
    task check8;
        input [7:0] got;
        input [7:0] exp;
        input integer tag;
        begin
            total_checks = total_checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  FAIL [%0d]: got 0x%02h expected 0x%02h", tag, got, exp);
            end
        end
    endtask

    // ---- matrix generators ---------------------------------------------
    task fill_random;
        input integer zero_pct;
        integer i;
        reg [31:0] r;
        begin
            for (i = 0; i < 16; i = i + 1) begin
                r = $random(seed);
                if ((r[30:0] % 100) < zero_pct) A[i] = 8'h00;
                else                            A[i] = $random(seed);
                r = $random(seed);
                if ((r[30:0] % 100) < zero_pct) B[i] = 8'h00;
                else                            B[i] = $random(seed);
            end
        end
    endtask

    task zero_acol;       // A[:,k] = 0
        input integer k;
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1) A[i*4 + k] = 8'h00;
        end
    endtask

    task zero_brow;       // B[k,:] = 0
        input integer k;
        integer j;
        begin
            for (j = 0; j < 4; j = j + 1) B[k*4 + j] = 8'h00;
        end
    endtask

    // ---- building blocks for a run -------------------------------------

    // Read A (0x00..0x0F) and B (0x10..0x1F) back and compare with the arrays.
    task verify_ab;
        input integer tag;
        integer i;
        reg [7:0] rd;
        begin
            spi_begin;
            spi_byte(8'h00, dummy);                       // read @0x00
            for (i = 0; i < 32; i = i + 1) begin spi_byte(8'h00, rd); rxb[i] = rd; end
            spi_end;
            for (i = 0; i < 16; i = i + 1) check8(rxb[i],      A[i], tag + i);
            for (i = 0; i < 16; i = i + 1) check8(rxb[16 + i], B[i], tag + 16 + i);
        end
    endtask

    // Burst-write A then B, then read them back.
    task load_ab;
        integer i;
        begin
            spi_begin;
            spi_byte(8'h80, dummy);                       // write @0x00
            for (i = 0; i < 16; i = i + 1) spi_byte(A[i], dummy);
            for (i = 0; i < 16; i = i + 1) spi_byte(B[i], dummy);
            spi_end;
            verify_ab(100);
        end
    endtask

    task start_run;
        input integer n;
        begin
            last_size = n;
            spi_wr1(7'h20, {4'b0000, n[2:0], 1'b1});
        end
    endtask

    // Poll STATUS until done && !busy. Leaves the final value in 'st'.
    task poll_done;
        integer to;
        begin
            to = 0;
            st = 8'h00;
            while (!(st[1] && !st[0]) && to < 100) begin
                spi_rd1(7'h21, st);
                to = to + 1;
            end
            total_checks = total_checks + 1;
            if (to >= 100) begin
                errors = errors + 1;
                $display("  FAIL: timed out waiting for done");
            end
        end
    endtask

    // Compare nnz/skipped (in 'st') and the irq/busy pins with the reference.
    task check_status;
        input integer id;
        input integer n;
        integer i, k, exp_nnz;
        reg any_a, any_b;
        begin
            exp_nnz = 0;
            for (k = 0; k < n; k = k + 1) begin
                any_a = 1'b0;
                any_b = 1'b0;
                for (i = 0; i < n; i = i + 1) begin
                    if (A[i*4 + k] != 8'h00) any_a = 1'b1;
                    if (B[k*4 + i] != 8'h00) any_b = 1'b1;
                end
                if (any_a && any_b) exp_nnz = exp_nnz + 1;
            end
            check8({5'b0, st[4:2]}, exp_nnz,     300 + id);
            check8({5'b0, st[7:5]}, n - exp_nnz, 400 + id);
            $display("  nnz_k=%0d skipped=%0d (expected %0d / %0d)",
                     st[4:2], st[7:5], exp_nnz, n - exp_nnz);

            total_checks = total_checks + 2;
            if (irq !== 1'b1)  begin errors = errors + 1; $display("  FAIL: irq not set after done"); end
            if (busy !== 1'b0) begin errors = errors + 1; $display("  FAIL: busy still high");        end
        end
    endtask

    // Read the whole result window and compare with the software reference.
    task check_result;
        input integer n;
        integer i, j, k, e, acc, got;
        reg [7:0] rd;
        begin
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    acc = 0;
                    if (i < n && j < n)
                        for (k = 0; k < n; k = k + 1)
                            acc = acc + A[i*4 + k] * B[k*4 + j];
                    expc[i*4 + j] = acc;
                end

            spi_begin;
            spi_byte(8'h40, dummy);                       // read @0x40
            for (i = 0; i < 64; i = i + 1) begin spi_byte(8'h00, rd); rxb[i] = rd; end
            spi_end;

            for (e = 0; e < 16; e = e + 1) begin
                got = {rxb[4*e + 3], rxb[4*e + 2], rxb[4*e + 1], rxb[4*e]};
                total_checks = total_checks + 1;
                if (got !== expc[e]) begin
                    errors = errors + 1;
                    $display("  FAIL: C[%0d][%0d] got %0d expected %0d",
                             e/4, e%4, got, expc[e]);
                end
            end
        end
    endtask

    // Full case: load A/B, run, check everything.
    task run_case;
        input integer id;
        input integer n;
        begin
            $display("Case %0d: active_size=%0d", id, n);
            load_ab;
            start_run(n);
            poll_done;
            check_status(id, n);
            check_result(n);
        end
    endtask

    // Re-run on the data already inside the chip (no reload of A/B).
    // The software model still uses A[]/B[], which the chip must not have
    // altered. do_read=0 skips the result readout, so the next start follows
    // right behind the previous run.
    task rerun_case;
        input integer id;
        input integer n;
        input integer do_read;
        begin
            $display("Case %0d: re-run WITHOUT reload, active_size=%0d%s", id, n,
                     do_read ? "" : " (result not read)");
            start_run(n);
            poll_done;
            check_status(id, n);
            if (do_read) check_result(n);
        end
    endtask

    // ---- write-while-busy guard ----------------------------------------
    // A real run is only ~20 clk cycles, shorter than one SPI byte at any
    // legal sclk rate, so the guard cannot be hit organically. Force the
    // core's busy signal instead.
    // Precondition: the previous run left done=1, and A[]/B[] hold the chip's
    // contents.
    task test_write_while_busy;
        reg [7:0] r;
        begin
            $display("Write-while-busy guard (busy forced inside DUT)");

            force dut.core_busy = 1'b1;
            repeat (4) @(posedge clk);

            spi_rd1(7'h21, r);
            check8({7'b0, r[0]}, 8'h01, 500);         // STATUS shows busy
            total_checks = total_checks + 1;
            if (busy !== 1'b1) begin errors = errors + 1; $display("  FAIL: busy pin not high"); end

            spi_wr1(7'h00, 8'hAA);                          // try to overwrite A[0]
            spi_wr1(7'h15, 8'h55);                          // try to overwrite B[5]
            spi_wr1(7'h20, {4'b0000, 3'd2, 1'b1});         // try size=2 + start

            release dut.core_busy;
            repeat (4) @(posedge clk);

            // nothing must have changed
            verify_ab(600);
            spi_rd1(7'h20, r);
            check8(r, {4'b0000, last_size[2:0], 1'b0}, 650);   // size unchanged
            spi_rd1(7'h21, r);
            check8({6'b0, r[1:0]}, 8'h02, 651);                // done still set, not busy
                                                               // (a start would have cleared it)

            // control experiment: the same A write now must take effect
            spi_wr1(7'h00, 8'hAA);
            spi_rd1(7'h00, r);
            check8(r, 8'hAA, 652);
            spi_wr1(7'h00, A[0]);                           // restore
            spi_rd1(7'h00, r);
            check8(r, A[0], 653);
        end
    endtask

    // ---- main sequence -------------------------------------------------
    integer i;

    initial begin
        $dumpfile("tb_systolic_chip_top.vcd");
        $dumpvars(0, tb_systolic_chip_top);

        errors = 0;
        total_checks = 0;
        seed = 32'h1234_5678;
        last_size = 4;

        $display("CONFIG: clk period %0d ns, sclk period %0d ns, clk/sclk = %0d, jitter %s",
                 2*CLK_HALF, 2*SCLK_HALF, SCLK_HALF/CLK_HALF, JITTER_EN ? "ON" : "OFF");
        if (SCLK_HALF < 8*CLK_HALF)
            $display("WARNING: clk/sclk < 8, outside the supported range; failures are expected");

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);

        // --- link sanity ---
        spi_rd1(7'h22, tmp);  check8(tmp, 8'h5A, 1);          // ID
        spi_rd1(7'h20, tmp);  check8(tmp, 8'h08, 2);          // default size = 4

        // --- invalid active_size writes must be ignored ---
        spi_wr1(7'h20, 8'h00);                                 // size 0
        spi_rd1(7'h20, tmp);  check8(tmp, 8'h08, 3);
        spi_wr1(7'h20, {4'b0000, 3'd7, 1'b0});                 // size 7
        spi_rd1(7'h20, tmp);  check8(tmp, 8'h08, 4);

        // --- aborted transaction must not upset the slave ---
        jit;
        cs_n = 1'b0; #(SCLK_HALF);
        for (i = 0; i < 3; i = i + 1) begin
            jit; mosi = 1'b1; #(SCLK_HALF);
            jit; sclk = 1'b1; #(SCLK_HALF);
            jit; sclk = 1'b0;
        end
        jit;
        cs_n = 1'b1; #(4*SCLK_HALF);
        spi_rd1(7'h22, tmp);  check8(tmp, 8'h5A, 5);

        // --- case 1: dense random, full 4x4 ---
        fill_random(0);
        run_case(1, 4);

        // --- case 2: structured sparsity (A col 1 zero, B row 2 zero) ---
        fill_random(20);
        zero_acol(1);
        zero_brow(2);
        run_case(2, 4);

        // --- case 3: 3x3 sub-block, sparse ---
        fill_random(40);
        zero_acol(1);                  // guarantees k=1 is skipped
        run_case(3, 3);

        // --- case 4: all zeros (SCAN -> DONE path, nnz_k = 0) ---
        for (i = 0; i < 16; i = i + 1) begin A[i] = 8'h00; B[i] = 8'h00; end
        run_case(4, 4);

        // --- case 5: 2x2 ---
        fill_random(0);
        run_case(5, 2);

        // --- case 6: 1x1 ---
        fill_random(0);
        run_case(6, 1);

        // --- case 7: identity x random  (C should equal B) ---
        fill_random(0);
        for (i = 0; i < 16; i = i + 1) A[i] = 8'h00;
        for (i = 0; i < 4;  i = i + 1) A[i*4 + i] = 8'h01;
        run_case(7, 4);

        // --- case 8: worst case magnitude (all 255) ---
        for (i = 0; i < 16; i = i + 1) begin A[i] = 8'hFF; B[i] = 8'hFF; end
        run_case(8, 4);

        // --- case 9/10: back-to-back with fresh random data ---
        fill_random(30);
        run_case(9, 4);
        fill_random(30);
        run_case(10, 4);

        // --- case 11-14: re-runs WITHOUT reloading A/B -------------------
        // Same size twice: if the accumulators were not cleared between runs
        // the result would double.
        rerun_case(11, 4, 1);
        rerun_case(12, 4, 1);
        // Run, skip the readout, and start again right away with a smaller size.
        rerun_case(13, 4, 0);
        rerun_case(14, 2, 1);
        rerun_case(15, 3, 1);
        verify_ab(700);                       // chip's A/B must be untouched

        // --- write-while-busy guard ---
        rerun_case(16, 4, 1);                 // leaves done=1, size=4
        test_write_while_busy;
        rerun_case(17, 4, 1);                 // still fully functional afterwards

        $display("--------------------------------------------");
        if (errors == 0)
            $display("PASS: %0d checks, 0 errors", total_checks);
        else
            $display("FAIL: %0d errors out of %0d checks", errors, total_checks);
        $finish;
    end

    // watchdog (scales with the sclk period)
    initial begin
        #(400000 * SCLK_HALF);
        $display("FAIL: global timeout");
        $finish;
    end

endmodule

