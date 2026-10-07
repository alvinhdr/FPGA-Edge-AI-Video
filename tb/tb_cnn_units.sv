// =============================================================================
// File   : tb_cnn_units.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Self-checking unit tests for the CNN datapath blocks:
//   cnn_requant : random + edge cases (negative -> 0, saturation -> 255, rounding
//                 exactly at .5, all shifts 15..40) vs a reference written with
//                 64-bit integer math in the testbench
//   cnn_argmax  : random vectors and TIES (equal maxima -> smallest index, conf 0)
//   cnn_mac_array (P=4): random sequences of first/accumulate vs a reference sum
// Prints "TEST PASSED" or "TEST FAILED".
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_cnn_units;
    import cnn_pkg::*;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    int errors = 0;

    // ------------------------------------------------------------------ requant
    logic               rq_in_v = 0, rq_out_v;
    logic signed [31:0] rq_acc;
    logic [15:0]        rq_m;
    logic [5:0]         rq_s;
    logic [11:0]        rq_tag_in, rq_tag_out;
    logic [7:0]         rq_q;

    cnn_requant #(.TAG_W(12)) u_rq (.clk(clk), .i_valid(rq_in_v), .i_acc(rq_acc), .i_m(rq_m), .i_s(rq_s),
                                    .i_tag(rq_tag_in), .o_valid(rq_out_v), .o_q(rq_q), .o_tag(rq_tag_out));

    function automatic logic [7:0] rq_ref(input longint acc, input longint m, input int s);
        longint v = (acc * m + (64'sd1 <<< (s - 1))) >>> s;
        return (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : 8'(v);
    endfunction

    // Expected values queue (tag = index)
    logic [7:0] rq_exp [4096];
    int rq_n = 0, rq_checked = 0;

    always @(posedge clk) begin
        if (rq_out_v) begin
            if (rq_q !== rq_exp[rq_tag_out]) begin
                if (errors < 10) $display("ERROR requant #%0d: got %0d expected %0d", rq_tag_out, rq_q, rq_exp[rq_tag_out]);
                errors++;
            end
            rq_checked++;
        end
    end

    task automatic rq_push(input longint acc, input int m, input int s);
        @(negedge clk);
        rq_in_v = 1; rq_acc = 32'(acc); rq_m = 16'(m); rq_s = 6'(s); rq_tag_in = 12'(rq_n);
        rq_exp[rq_n] = rq_ref(acc, m, s);
        rq_n++;
    endtask

    // ------------------------------------------------------------------ argmax
    logic                    am_start = 0, am_done;
    logic signed [ACC_W-1:0] am_acc [NFC];
    logic [3:0]              am_digit;
    logic [7:0]              am_conf;
    localparam int MC = 26807, SC = 21;

    cnn_argmax #(.MC(MC), .SC(SC)) u_am (.clk(clk), .rst_n(rst_n), .i_start(am_start), .i_acc(am_acc),
                                         .o_done(am_done), .o_digit(am_digit), .o_conf(am_conf));

    task automatic am_check(input string what);
        int best = 0; longint t1, t2 = -(64'sd1 <<< 40), c;
        for (int k = 1; k < NFC; k++) if (am_acc[k] > am_acc[best]) best = k;
        t1 = am_acc[best];
        for (int k = 0; k < NFC; k++) if (k != best && am_acc[k] > t2) t2 = am_acc[k];
        c = ((t1 - t2) * MC + (64'sd1 <<< (SC - 1))) >>> SC;
        if (c > 255) c = 255;
        @(negedge clk); am_start = 1;
        @(negedge clk); am_start = 0;
        while (!am_done) @(negedge clk);
        if (am_digit !== best || am_conf !== c) begin
            $display("ERROR argmax (%s): got digit %0d conf %0d, expected %0d %0d", what, am_digit, am_conf, best, c);
            errors++;
        end
    endtask

    // ------------------------------------------------------------------ MAC array (P = 4)
    localparam int PT = 4;
    logic                    mac_v = 0, mac_first = 0;
    logic [7:0]              mac_x;
    logic [PT*8-1:0]         mac_w;
    logic [PT*32-1:0]        mac_b;
    logic signed [ACC_W-1:0] mac_acc [PT];
    longint                  mac_ref [PT];

    cnn_mac_array #(.P(PT)) u_mac (.clk(clk), .i_valid(mac_v), .i_first(mac_first), .i_x(mac_x),
                                   .i_w(mac_w), .i_bias(mac_b), .o_acc(mac_acc));

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;

        // ---- requant: edge cases, then random -------------------------------------
        for (int s = 15; s <= 40; s++) begin
            rq_push(0, 16384, s);
            rq_push(-1, 32767, s);                               // small negative -> 0
            rq_push(longint'(1) << (s - 15), 16384, s);          // exactly x.5 -> rounds up
            rq_push((longint'(1) << 24) - 1, 32767, s);          // largest allowed acc
            rq_push(-(longint'(1) << 24), 32767, s);             // most negative acc -> 0
        end
        rq_push(255 * 128, 16384, 21);   // -> 255 exactly-ish region
        rq_push(256 * 128, 16384, 21);   // saturates
        for (int i = 0; i < 2000; i++)
            rq_push($signed($urandom_range(0, 1 << 25)) - (1 << 24), $urandom_range(16384, 32767), $urandom_range(15, 40));
        @(negedge clk); rq_in_v = 0;
        repeat (6) @(posedge clk);
        if (rq_checked != rq_n) begin $display("ERROR requant: %0d outputs for %0d inputs", rq_checked, rq_n); errors++; end

        // ---- argmax: ties and random ---------------------------------------------------
        foreach (am_acc[k]) am_acc[k] = 100;
        am_check("all equal -> digit 0, conf 0");
        foreach (am_acc[k]) am_acc[k] = -5;
        am_acc[3] = 7; am_acc[8] = 7;
        am_check("tie between 3 and 8 -> 3");
        foreach (am_acc[k]) am_acc[k] = -1000000;
        am_acc[9] = 2000000;
        am_check("last index wins, huge margin -> conf 255");
        for (int i = 0; i < 300; i++) begin
            foreach (am_acc[k]) am_acc[k] = $signed($urandom_range(0, 1 << 20)) - (1 << 19);
            am_check("random");
        end

        // ---- MAC array: random runs of sums -----------------------------------------------
        for (int run = 0; run < 200; run++) begin
            int len = $urandom_range(1, 80);
            for (int t = 0; t < len; t++) begin
                @(negedge clk);
                mac_v = 1; mac_first = (t == 0);
                mac_x = 8'($urandom);
                for (int p = 0; p < PT; p++) begin
                    mac_w[8*p +: 8]  = 8'($urandom_range(0, 254) - 127 + 256);
                    mac_b[32*p +: 32] = 32'($signed($urandom_range(0, 1 << 20)) - (1 << 19));
                    if (t == 0) mac_ref[p] = $signed(mac_b[32*p +: 32]);
                    mac_ref[p] += longint'(mac_x) * longint'($signed(mac_w[8*p +: 8]));
                end
            end
            @(negedge clk); mac_v = 0;
            @(negedge clk);                 // MAC latency is 2 clocks
            for (int p = 0; p < PT; p++)
                if (mac_acc[p] !== 32'(mac_ref[p])) begin
                    if (errors < 10) $display("ERROR mac run %0d lane %0d: got %0d expected %0d", run, p, mac_acc[p], mac_ref[p]);
                    errors++;
                end
        end

        $display("requant: %0d values checked; argmax: 303 vectors; mac: 200 random sums x %0d lanes", rq_checked, PT);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule

`default_nettype wire
