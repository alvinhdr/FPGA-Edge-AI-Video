// =============================================================================
// File   : tb_ai_core.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: System testbench for rtl/ai_core.sv (AXI-Lite regs + CNN + inject RAM +
//          start logic + ROI port sharing), driven like the ARM would drive it.
//   1. ID and reset values
//   2. Inject mode: write golden test image k into the inject RAM over AXI, write
//      CNN_START, poll RESULT, compare digit, confidence, the 10 FC accumulators
//      and CNN_CYCLES with ml/export vectors (images 0..9)
//   3. Auto mode: the TB writes image k into ROI bank 1 (like roi_capture), sets
//      ready bank = 1 and pulses frame-done -> the CNN must start by itself and
//      produce the golden result (images 10..14); AXI ROI readback still works
//   4. cnn_enable = 0: a frame pulse must NOT start the CNN
// Prints "TEST PASSED" or "TEST FAILED".
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ai_core;

    localparam int NFULL = 20, IN_B = 784, NFC = 10;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    // AXI master signals
    logic [15:0] awaddr = '0, araddr = '0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = '0;
    logic [3:0]  wstrb = '0;
    logic        awready, wready, bvalid, arready, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;

    // ROI buffer model (dual-port RAM, port A = TB as roi_capture, port B = DUT)
    logic        roi_we = 0;
    logic [10:0] roi_waddr = '0, roi_raddr;
    logic [7:0]  roi_wdata = '0, roi_rdata;
    logic        frame_pulse = 0, ready_bank = 0;

    ram_tdp #(.DW(8), .AW(11)) u_roi (
        .clk_a(clk), .we_a(roi_we), .addr_a(roi_waddr), .din_a(roi_wdata), .dout_a(),
        .clk_b(clk), .we_b(1'b0), .addr_b(roi_raddr), .din_b(8'd0), .dout_b(roi_rdata));

    logic        invert, thresh_en, freeze, res_valid, ov_valid;
    logic [7:0]  thresh, conf;
    logic [10:0] roi_x0, roi_y0;
    logic [3:0]  digit;

    ai_core dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .o_roi_addr(roi_raddr), .i_roi_data(roi_rdata),
        .i_frame_pulse(frame_pulse), .i_ready_bank(ready_bank),
        .o_invert(invert), .o_thresh_en(thresh_en), .o_freeze(freeze), .o_thresh(thresh),
        .o_roi_x0(roi_x0), .o_roi_y0(roi_y0),
        .o_result_valid(res_valid), .o_overlay_valid(ov_valid), .o_digit(digit), .o_conf(conf));

    // Golden vectors
    logic [IN_B*8-1:0] v_in  [NFULL];
    logic [NFC*32-1:0] v_acc [NFULL];
    logic [11:0]       v_res [NFULL];

    int errors = 0;

    // ---------------- AXI4-Lite master ----------------
    task automatic axi_write(input logic [15:0] addr, input logic [31:0] data);
        @(posedge clk);
        awaddr <= addr; awvalid <= 1; wdata <= data; wstrb <= 4'hF; wvalid <= 1;
        do @(posedge clk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0; bready <= 1;
        do @(posedge clk); while (!bvalid);
        bready <= 0;
    endtask

    task automatic axi_read(input logic [15:0] addr, output logic [31:0] data);
        @(posedge clk);
        araddr <= addr; arvalid <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0; rready <= 1;
        do @(posedge clk); while (!rvalid);
        data = rdata;
        rready <= 0;
    endtask

    task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("ERROR %s: got 0x%08h (%0d), expected 0x%08h (%0d)", what, got, $signed(got), exp, $signed(exp));
            errors++;
        end
    endtask

    // Wait until CNN_COUNT reaches n (polling like the ARM), then check RESULT and FC regs
    task automatic wait_and_check(input int n, input int k, input string mode);
        logic [31:0] r;
        int guard = 0;
        do begin axi_read(16'h0024, r); guard++; end while (r < n && guard < 20000);
        if (r != n) begin $display("ERROR %s img %0d: CNN_COUNT %0d, expected %0d", mode, k, r, n); errors++; end
        axi_read(16'h001C, r);
        expect_eq($sformatf("%s img %0d RESULT", mode, k), r, {1'b0, 14'd0, 1'b1, v_res[k][7:0], 4'd0, v_res[k][11:8]});
        for (int j = 0; j < NFC; j++) begin
            axi_read(16'h0040 + 16'(4 * j), r);
            expect_eq($sformatf("%s img %0d FC[%0d]", mode, k, j), r, v_acc[k][(NFC - 1 - j) * 32 +: 32]);
        end
        if (res_valid !== 1'b1 || digit !== v_res[k][11:8] || conf !== v_res[k][7:0]) begin
            $display("ERROR %s img %0d: result ports digit %0d conf %0d valid %0d", mode, k, digit, conf, res_valid);
            errors++;
        end
    endtask

    initial begin
        logic [31:0] r, cyc;
        $readmemh("vec_full_input.mem",  v_in);
        $readmemh("vec_full_acc.mem",    v_acc);
        $readmemh("vec_full_result.mem", v_res);

        repeat (5) @(posedge clk);
        rst_n <= 1;
        repeat (2) @(posedge clk);

        // 1. ID / reset values
        axi_read(16'h0000, r); expect_eq("ID", r, 32'hED6E_0006);
        axi_read(16'h0004, r); expect_eq("CTRL reset", r, 32'h0000_0009);
        axi_read(16'h001C, r); expect_eq("RESULT before any inference", r, 32'h0);
        axi_read(16'h0028, r); expect_eq("CONF_MIN reset", r, 32'h0);
        expect_eq("overlay valid before any inference", ov_valid, 1'b0);

        // 2. Inject mode, images 0..9
        axi_write(16'h0004, 32'h0000_0019);                  // invert, cnn_enable, inject_mode
        for (int k = 0; k < 10; k++) begin
            for (int i = 0; i < IN_B; i++) axi_write(16'h2000 + 16'(4 * i), {24'd0, v_in[k][(IN_B - 1 - i) * 8 +: 8]});
            frame_pulse <= 1; @(posedge clk); frame_pulse <= 0;   // must be IGNORED in inject mode
            axi_write(16'h0018, 32'h1);                           // CNN_START
            wait_and_check(k + 1, k, "inject");
        end
        axi_read(16'h0020, cyc);
        $display("CNN_CYCLES (hardware counter, read over AXI) = %0d", cyc);

        // 3. Auto mode, images 10..14: TB plays roi_capture (writes bank 1, then frame done)
        axi_write(16'h0004, 32'h0000_0009);                  // invert, cnn_enable
        for (int k = 10; k < 15; k++) begin
            for (int i = 0; i < IN_B; i++) begin
                @(posedge clk); roi_we <= 1; roi_waddr <= 11'(1024 + i); roi_wdata <= v_in[k][(IN_B - 1 - i) * 8 +: 8];
            end
            @(posedge clk); roi_we <= 0; ready_bank <= 1;
            repeat (3) @(posedge clk);
            frame_pulse <= 1; @(posedge clk); frame_pulse <= 0;
            wait_and_check(k + 1, k, "auto");
        end
        axi_read(16'h1000 + 16'(4 * 100), r);                // AXI ROI readback (CNN idle): pixel 100 of bank 1
        expect_eq("ROI readback", r, {24'd0, v_in[14][(IN_B - 1 - 100) * 8 +: 8]});

        // 4. cnn_enable = 0: frame pulse must not start the CNN
        axi_write(16'h0004, 32'h0000_0001);
        frame_pulse <= 1; @(posedge clk); frame_pulse <= 0;
        repeat (30000) @(posedge clk);
        axi_read(16'h0024, r); expect_eq("CNN_COUNT unchanged with cnn_enable=0", r, 32'd15);

        // 5. CONF_MIN: the overlay hides low-confidence results, the RESULT register does not.
        //    The last result is image 14: conf c. Default CONF_MIN = 0 shows everything.
        begin
            logic [7:0] c;
            c = v_res[14][7:0];
            expect_eq("overlay shows the result with CONF_MIN = 0", ov_valid, 1'b1);
            axi_write(16'h0028, {24'd0, c});                  // conf == CONF_MIN -> still shown
            repeat (3) @(posedge clk);
            expect_eq("overlay shows conf == CONF_MIN", ov_valid, 1'b1);
            if (c != 8'hFF) begin
                axi_write(16'h0028, {24'd0, 8'(c + 8'd1)});   // conf < CONF_MIN -> hidden
                repeat (3) @(posedge clk);
                expect_eq("overlay hides conf < CONF_MIN", ov_valid, 1'b0);
                expect_eq("raw result valid is NOT filtered", res_valid, 1'b1);
                axi_read(16'h001C, r);
                expect_eq("RESULT register is NOT filtered", r, {1'b0, 14'd0, 1'b1, v_res[14][7:0], 4'd0, v_res[14][11:8]});
            end
            axi_write(16'h0028, 32'd255);
            repeat (3) @(posedge clk);
            expect_eq("overlay with CONF_MIN = 255", ov_valid, (c == 8'hFF) ? 1'b1 : 1'b0);
            axi_write(16'h0028, 32'd0);
            repeat (3) @(posedge clk);
            expect_eq("overlay shows the result again with CONF_MIN = 0", ov_valid, 1'b1);
            $display("checked: CONF_MIN overlay filter (boundary conf == CONF_MIN, conf + 1, 255, back to 0)");
        end

        $display("checked: 10 inject-mode + 5 auto-mode inferences over AXI");
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
