// =============================================================================
// File   : tb_cdc.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Self-checking testbench for cdc_bus_sync and cdc_pulse_sync with two
//          unrelated clocks, in BOTH directions (fast->slow and slow->fast):
//            clk_a = 100 MHz (like clk_acc), clk_b = 74.25 MHz (like clk_pix)
//
//   cdc_bus_sync : the source counts up 0,1,2,... with random gaps, including
//                  bursts that change EVERY clock. Checks:
//                  - every destination value is a value the source really had
//                    (never a mix of old and new bits),
//                  - values arrive in order (never go backwards),
//                  - after the source stops, the destination ends at the last value.
//   cdc_pulse_sync: random toggles (at least 8 source clocks apart). Checks that
//                  the number of destination pulses == number of toggles.
// Prints "TEST PASSED" or "TEST FAILED".
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_cdc;

    localparam int W = 16;

    logic clk_a = 1'b0, clk_b = 1'b0;
    always #5.000 clk_a = ~clk_a;     // 100 MHz
    always #6.734 clk_b = ~clk_b;     // 74.25 MHz

    int errors = 0;

    // ---------------- bus sync, a -> b and b -> a ----------------
    logic [W-1:0] src_ab = '0, dst_ab, src_ba = '0, dst_ba;

    cdc_bus_sync #(.W(W)) u_bus_ab (.clk_src(clk_a), .i_data(src_ab), .clk_dst(clk_b), .o_data(dst_ab));
    cdc_bus_sync #(.W(W)) u_bus_ba (.clk_src(clk_b), .i_data(src_ba), .clk_dst(clk_a), .o_data(dst_ba));

    // Checker: values must never decrease and never exceed what the source has sent.
    logic [W-1:0] last_ab = '0, last_ba = '0;
    int           n_seen_ab = 0, n_seen_ba = 0;
    always @(posedge clk_b) begin
        if (dst_ab !== last_ab) begin
            if ($isunknown(dst_ab) || dst_ab < last_ab || dst_ab > src_ab) begin
                $display("ERROR a->b: got %0d after %0d (source now %0d)", dst_ab, last_ab, src_ab);
                errors++;
            end
            last_ab = dst_ab;
            n_seen_ab++;
        end
    end
    always @(posedge clk_a) begin
        if (dst_ba !== last_ba) begin
            if ($isunknown(dst_ba) || dst_ba < last_ba || dst_ba > src_ba) begin
                $display("ERROR b->a: got %0d after %0d (source now %0d)", dst_ba, last_ba, src_ba);
                errors++;
            end
            last_ba = dst_ba;
            n_seen_ba++;
        end
    end

    // ---------------- pulse sync, a -> b and b -> a ----------------
    logic tgl_a = 1'b0, tgl_b = 1'b0, pulse_ab, pulse_ba;
    int   n_tgl_a = 0, n_tgl_b = 0, n_pulse_ab = 0, n_pulse_ba = 0;

    cdc_pulse_sync u_pulse_ab (.clk_dst(clk_b), .i_src_toggle(tgl_a), .o_dst_pulse(pulse_ab));
    cdc_pulse_sync u_pulse_ba (.clk_dst(clk_a), .i_src_toggle(tgl_b), .o_dst_pulse(pulse_ba));

    always @(posedge clk_b) if (pulse_ab) n_pulse_ab++;
    always @(posedge clk_a) if (pulse_ba) n_pulse_ba++;

    // ---------------- stimulus ----------------
    task automatic drive_bus_a(input int n);
        repeat (n) begin
            @(posedge clk_a);
            if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 40)) @(posedge clk_a);  // gaps
            src_ab <= src_ab + 1'b1;                                                         // else: burst
        end
    endtask

    task automatic drive_bus_b(input int n);
        repeat (n) begin
            @(posedge clk_b);
            if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 40)) @(posedge clk_b);
            src_ba <= src_ba + 1'b1;
        end
    endtask

    task automatic drive_pulses_a(input int n);
        repeat (n) begin
            repeat ($urandom_range(8, 30)) @(posedge clk_a);
            tgl_a <= ~tgl_a;
            n_tgl_a++;
        end
    endtask

    task automatic drive_pulses_b(input int n);
        repeat (n) begin
            repeat ($urandom_range(8, 30)) @(posedge clk_b);
            tgl_b <= ~tgl_b;
            n_tgl_b++;
        end
    endtask

    initial begin
        fork
            drive_bus_a(3000);
            drive_bus_b(3000);
            drive_pulses_a(500);
            drive_pulses_b(500);
        join
        repeat (50) @(posedge clk_a);    // let the last transfers finish

        if (dst_ab !== src_ab) begin $display("ERROR a->b final %0d != %0d", dst_ab, src_ab); errors++; end
        if (dst_ba !== src_ba) begin $display("ERROR b->a final %0d != %0d", dst_ba, src_ba); errors++; end
        if (n_pulse_ab != n_tgl_a) begin $display("ERROR pulses a->b %0d != %0d", n_pulse_ab, n_tgl_a); errors++; end
        if (n_pulse_ba != n_tgl_b) begin $display("ERROR pulses b->a %0d != %0d", n_pulse_ba, n_tgl_b); errors++; end

        $display("bus a->b: source sent %0d values, destination saw %0d distinct (skips are allowed)", src_ab, n_seen_ab);
        $display("bus b->a: source sent %0d values, destination saw %0d distinct", src_ba, n_seen_ba);
        $display("pulses a->b %0d/%0d, b->a %0d/%0d", n_pulse_ab, n_tgl_a, n_pulse_ba, n_tgl_b);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule

`default_nettype wire
