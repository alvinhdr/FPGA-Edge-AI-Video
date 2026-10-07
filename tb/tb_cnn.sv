// =============================================================================
// File   : tb_cnn.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Self-checking testbench for rtl/cnn_top.sv against the golden model
//          test vectors from ml/export.py (scripts/sim_cnn.py runs it).
//
//   +full1  : 20 images, compare EVERY layer: P1, P2 feature maps (read from the
//             accelerator's RAMs), 10 FC accumulators, digit, confidence
//   +full0  : first +n<N> of the 1000-image set: FC accumulators, digit, confidence,
//             and accuracy against the true labels
// The number of MACs P comes from tb_cnn_cfg.svh (written by the runner).
// Prints "TEST PASSED" or "TEST FAILED".
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_cnn;
    import cnn_pkg::*;
    `include "tb_cnn_cfg.svh"          // localparam int TB_P

    localparam string WF = (TB_P == 1) ? "wrom_p1.mem" : (TB_P == 2) ? "wrom_p2.mem" :
                           (TB_P == 4) ? "wrom_p4.mem" : (TB_P == 8) ? "wrom_p8.mem" : "wrom_p16.mem";
    localparam string BF = (TB_P == 1) ? "brom_p1.mem" : (TB_P == 2) ? "brom_p2.mem" :
                           (TB_P == 4) ? "brom_p4.mem" : (TB_P == 8) ? "brom_p8.mem" : "brom_p16.mem";

    localparam int NFULL = 20, NBIG = 1000;
    localparam int IN_B = 784, P1_B = C1 * P1_HW * P1_HW, P2_B = FC_IN;

    logic clk = 1'b0, rst_n = 1'b0, start = 1'b0;
    always #5 clk = ~clk;              // 100 MHz

    logic        busy, done;
    logic [9:0]  in_addr;
    logic [7:0]  in_data;
    logic [3:0]  digit;
    logic [7:0]  conf;
    logic signed [ACC_W-1:0] fc_acc [NFC];
    logic [31:0] cycles;

    // Input image memory (like the ROI buffer): 1-clock read latency
    logic [7:0] img [IN_B];
    always_ff @(posedge clk) in_data <= img[in_addr];

    cnn_top #(.P(TB_P), .WROM_FILE(WF), .BROM_FILE(BF)) dut (
        .clk(clk), .rst_n(rst_n), .i_start(start), .o_busy(busy), .o_done(done),
        .o_in_addr(in_addr), .i_in_data(in_data),
        .o_digit(digit), .o_conf(conf), .o_fc_acc(fc_acc), .o_cycles(cycles));

    // Test vectors: one image per line, element 0 = leftmost (most significant) byte
    logic [IN_B*8-1:0]  v_in   [NBIG];
    logic [P1_B*8-1:0]  v_p1   [NFULL];
    logic [P2_B*8-1:0]  v_p2   [NFULL];
    logic [NFC*32-1:0]  v_acc  [NBIG];
    logic [11:0]        v_res  [NBIG];
    logic [3:0]         v_lab  [NBIG];

    int errors = 0, img_errors = 0, n_correct = 0;
    longint total_cycles = 0;

    function automatic logic [7:0] byte_of(input logic [P1_B*8-1:0] v, input int nbytes, input int i);
        return v[(nbytes - 1 - i) * 8 +: 8];
    endfunction

    task automatic run_image(input int idx, input bit full);
        int e = 0;
        for (int i = 0; i < IN_B; i++) img[i] = v_in[idx][(IN_B - 1 - i) * 8 +: 8];
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        do @(posedge clk); while (!done);
        @(posedge clk);
        total_cycles += cycles;

        if (full) begin
            for (int a = 0; a < P1_B; a++)
                if (dut.u_p1_ram.mem[a] !== byte_of(v_p1[idx], P1_B, a)) begin
                    if (e < 3) $display("  img %0d P1[%0d] (c%0d y%0d x%0d): got %0d expected %0d", idx, a,
                                        a / 169, (a % 169) / 13, a % 13, dut.u_p1_ram.mem[a], byte_of(v_p1[idx], P1_B, a));
                    e++;
                end
            for (int a = 0; a < P2_B; a++)
                if (dut.u_p2_ram.mem[a] !== byte_of({{(P1_B-P2_B)*8{1'b0}}, v_p2[idx]}, P2_B, a)) begin
                    if (e < 6) $display("  img %0d P2[%0d]: got %0d expected %0d", idx, a,
                                        dut.u_p2_ram.mem[a], byte_of({{(P1_B-P2_B)*8{1'b0}}, v_p2[idx]}, P2_B, a));
                    e++;
                end
        end
        for (int k = 0; k < NFC; k++)
            if (fc_acc[k] !== $signed(v_acc[idx][(NFC - 1 - k) * 32 +: 32])) begin
                if (e < 9) $display("  img %0d FC acc[%0d]: got %0d expected %0d", idx, k, fc_acc[k],
                                    $signed(v_acc[idx][(NFC - 1 - k) * 32 +: 32]));
                e++;
            end
        if (digit !== v_res[idx][11:8] || conf !== v_res[idx][7:0]) begin
            $display("  img %0d result: got digit %0d conf %0d, expected digit %0d conf %0d",
                     idx, digit, conf, v_res[idx][11:8], v_res[idx][7:0]);
            e++;
        end
        if (!full && digit == v_lab[idx]) n_correct++;
        errors += e;
        if (e) img_errors++;
    endtask

    initial begin
        int full, n;
        full = 1; n = NFULL;
        void'($value$plusargs("full%d", full));
        void'($value$plusargs("n%d", n));
        if (full) n = (n > NFULL) ? NFULL : n;

        if (full) begin
            $readmemh("vec_full_input.mem", v_in, 0, NFULL - 1);
            $readmemh("vec_full_p1.mem",    v_p1);
            $readmemh("vec_full_p2.mem",    v_p2);
            $readmemh("vec_full_acc.mem",   v_acc, 0, NFULL - 1);
            $readmemh("vec_full_result.mem", v_res, 0, NFULL - 1);
        end else begin
            $readmemh("vec_1000_input.mem",  v_in);
            $readmemh("vec_1000_acc.mem",    v_acc);
            $readmemh("vec_1000_result.mem", v_res);
            $readmemh("vec_1000_labels.mem", v_lab);
        end

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        for (int i = 0; i < n; i++) begin
            run_image(i, full);
            if (!full && (i + 1) % 100 == 0) $display("  ... %0d images, %0d with errors", i + 1, img_errors);
        end

        $display("P=%0d mode=%s images=%0d  images with errors=%0d  total mismatches=%0d",
                 TB_P, full ? "full-layers" : "fc+result", n, img_errors, errors);
        $display("CYCLES per inference = %0d (%.1f us at 100 MHz)", int'(total_cycles / n), real'(total_cycles) / n / 100.0);
        if (!full) $display("ACCURACY vs labels = %0d/%0d", n_correct, n);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

    initial begin
        #500_000_000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
