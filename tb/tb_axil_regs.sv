// =============================================================================
// File   : tb_axil_regs.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Self-checking testbench for rtl/axil_regs.sv (AXI4-Lite slave).
//          A small AXI4-Lite master (tasks below) with random delays checks:
//            - ID and reset values
//            - register write/read-back, unused bits masked, byte strobes
//            - address and data arriving in different clocks
//            - BREADY / RREADY held low for a while (slave must wait)
//            - frame counter, ready-bank status
//            - ROI readback through a real ram_tdp: correct bank and index,
//              out-of-range index returns 0, unknown address returns 0xDEADBEEF
// Prints "TEST PASSED" or "TEST FAILED".
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_axil_regs;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [15:0] awaddr = '0, araddr = '0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = '0;
    logic [3:0]  wstrb = '0;
    logic        awready, wready, bvalid, arready, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;

    logic        invert, thresh_en, freeze, frame_pulse = 0, ready_bank = 0;
    logic [7:0]  thresh, roi_data;
    logic [10:0] roi_x0, roi_y0, roi_addr;

    // ROI RAM: port A written by the TB (like roi_capture), port B read by the DUT
    logic        ram_we = 0;
    logic [10:0] ram_addr = '0;
    logic [7:0]  ram_din = '0;

    ram_tdp #(.DW(8), .AW(11)) u_ram (
        .clk_a(clk), .we_a(ram_we), .addr_a(ram_addr), .din_a(ram_din), .dout_a(),
        .clk_b(clk), .we_b(1'b0), .addr_b(roi_addr), .din_b(8'd0), .dout_b(roi_data));

    axil_regs dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .o_invert(invert), .o_thresh_en(thresh_en), .o_freeze(freeze), .o_thresh(thresh),
        .o_roi_x0(roi_x0), .o_roi_y0(roi_y0),
        .i_frame_pulse(frame_pulse), .i_ready_bank(ready_bank),
        .o_roi_addr(roi_addr), .i_roi_data(roi_data));

    int errors = 0;

    // ---------------- AXI4-Lite master tasks ----------------
    task automatic axi_write(input logic [15:0] addr, input logic [31:0] data,
                             input logic [3:0] strb = 4'hF);
        int gap = $urandom_range(0, 3);
        @(posedge clk);
        awaddr <= addr; awvalid <= 1;
        if (gap == 0) begin wdata <= data; wstrb <= strb; wvalid <= 1; end
        // address alone for a few clocks, then data (slave must wait for both)
        repeat (gap) @(posedge clk);
        wdata <= data; wstrb <= strb; wvalid <= 1;
        do @(posedge clk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        repeat ($urandom_range(0, 4)) @(posedge clk);    // BREADY late
        bready <= 1;
        do @(posedge clk); while (!bvalid);
        if (bresp != 2'b00) begin $display("ERROR write %h: BRESP %b", addr, bresp); errors++; end
        bready <= 0;
    endtask

    task automatic axi_read(input logic [15:0] addr, output logic [31:0] data);
        @(posedge clk);
        araddr <= addr; arvalid <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        repeat ($urandom_range(0, 4)) @(posedge clk);    // RREADY late
        rready <= 1;
        do @(posedge clk); while (!rvalid);
        data = rdata;
        if (rresp != 2'b00) begin $display("ERROR read %h: RRESP %b", addr, rresp); errors++; end
        rready <= 0;
    endtask

    task automatic expect_read(input logic [15:0] addr, input logic [31:0] exp, input string what);
        logic [31:0] got;
        axi_read(addr, got);
        if (got !== exp) begin
            $display("ERROR %s: read 0x%08h from 0x%04h, expected 0x%08h", what, got, addr, exp);
            errors++;
        end
    endtask

    // Fill RAM bank b with a known pattern: value = (index * 7 + b * 100) & 0xFF
    task automatic fill_bank(input int b);
        for (int i = 0; i < 784; i++) begin
            @(posedge clk);
            ram_we <= 1; ram_addr <= 11'(b * 1024 + i); ram_din <= 8'((i * 7 + b * 100) & 8'hFF);
        end
        @(posedge clk); ram_we <= 0;
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1;
        repeat (2) @(posedge clk);

        // Reset values
        expect_read(16'h0000, 32'hED6E_0004, "ID");
        expect_read(16'h0004, 32'h0000_0001, "CTRL reset (invert on)");
        expect_read(16'h0008, 32'd64,        "THRESH reset");
        expect_read(16'h000C, {5'd0, 11'd248, 5'd0, 11'd528}, "ROI_POS reset");
        expect_read(16'h0014, 32'd0,         "FRAME_CNT reset");
        if (!(invert && !thresh_en && !freeze && thresh == 64 && roi_x0 == 528 && roi_y0 == 248)) begin
            $display("ERROR: output ports do not show the reset values"); errors++;
        end

        // Write / read back, with masking of unused bits
        axi_write(16'h0004, 32'hFFFF_FFFE);           // invert 0, thresh_en 1, freeze 1
        expect_read(16'h0004, 32'h0000_0006, "CTRL write (masked)");
        if (invert || !thresh_en || !freeze) begin $display("ERROR: CTRL outputs"); errors++; end
        axi_write(16'h0008, 32'h1234_5678);
        expect_read(16'h0008, 32'h0000_0078, "THRESH write (masked to 8 bits)");
        axi_write(16'h000C, {5'h1F, 11'd400, 5'h1F, 11'd900});
        expect_read(16'h000C, {5'd0, 11'd400, 5'd0, 11'd900}, "ROI_POS write (masked)");
        if (roi_x0 != 900 || roi_y0 != 400) begin $display("ERROR: ROI outputs"); errors++; end

        // Byte strobe: change only byte 2 (the low byte of y0)
        axi_write(16'h000C, 32'h00AB_0000, 4'b0100);
        expect_read(16'h000C, {5'd0, 11'h1AB, 5'd0, 11'd900}, "ROI_POS byte-strobe write");

        // Writes to read-only registers are ignored
        axi_write(16'h0000, 32'h0);
        expect_read(16'h0000, 32'hED6E_0004, "ID is read-only");

        // Frame counter and status
        repeat (3) begin @(posedge clk); frame_pulse <= 1; @(posedge clk); frame_pulse <= 0; end
        expect_read(16'h0014, 32'd3, "FRAME_CNT after 3 pulses");
        ready_bank <= 1;
        expect_read(16'h0010, 32'd1, "STATUS ready bank 1");

        // ROI readback from the ready bank
        fill_bank(0);
        fill_bank(1);
        ready_bank <= 0;
        for (int i = 0; i < 784; i += 37) expect_read(16'h1000 + 16'(4 * i), 32'((i * 7) & 8'hFF), "ROI bank 0");
        expect_read(16'h1000 + 16'(4 * 783), 32'((783 * 7) & 8'hFF), "ROI bank 0 last pixel");
        ready_bank <= 1;
        for (int i = 0; i < 784; i += 37) expect_read(16'h1000 + 16'(4 * i), 32'((i * 7 + 100) & 8'hFF), "ROI bank 1");
        expect_read(16'h1000 + 16'(4 * 784), 32'd0,  "ROI index 784 (out of range) reads 0");
        expect_read(16'h0040, 32'hDEAD_BEEF,         "unused address");

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TEST FAILED (timeout: the slave did not respond)");
        $finish;
    end

endmodule

`default_nettype wire
