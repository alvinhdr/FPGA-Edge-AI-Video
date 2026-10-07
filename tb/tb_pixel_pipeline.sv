// =============================================================================
// File   : tb_pixel_pipeline.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Testbench for rtl/pixel_pipeline.sv. Plays a video stream file into
//          the pipeline and records everything that comes out.
//          Checking is done in Python (scripts/sim_pixel_pipeline.py), which
//          compares the output against a reference model, pixel by pixel.
//
// Files (in the simulation working directory):
//   stream_in.txt   : input stream, 1 line per pixel clock (see scripts/video_stream.py)
//   stream_out.txt  : output stream, same format, 1 line per pixel clock
//   roi_writes.txt  : every ROI buffer write "w <addr hex> <data hex>", and "f" each
//                     time the frame-done toggle changes
// Plusargs (no "=", because Windows .bat files split arguments at "="):
//   +gray<0|1> +overlay<0|1> +roix<n> +roiy<n> +digit<0..9> +inv<0|1> +then<0|1> +thr<n>
//   e.g. +gray1 +roix528
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_pixel_pipeline;
    import video_pkg::*;

    localparam real CLK_PERIOD_NS = 13.468;   // 74.25 MHz (720p60)
    localparam int  LATENCY       = 6;        // must match pixel_pipeline

    logic             clk_pix = 1'b0;
    video_t           in_vid  = '0;
    video_t           out_vid;

    int               gray_en    = 0;
    int               overlay_en = 1;
    int               roi_x0     = 528;
    int               roi_y0     = 248;
    int               digit      = 7;
    int               invert     = 1;
    int               thresh_en  = 0;
    int               thresh     = 64;

    logic             roi_we, frame_tgl, ready_bank;
    logic [10:0]      roi_addr;
    logic [7:0]       roi_data;

    always #(CLK_PERIOD_NS / 2.0) clk_pix = ~clk_pix;

    pixel_pipeline dut (
        .clk_pix        (clk_pix),
        .i_vid          (in_vid),
        .o_vid          (out_vid),
        .i_gray_en      (gray_en[0]),
        .i_overlay_en   (overlay_en[0]),
        .i_roi_x0       (roi_x0[POS_W-1:0]),
        .i_roi_y0       (roi_y0[POS_W-1:0]),
        .i_digit        (digit[3:0]),
        .i_invert       (invert[0]),
        .i_thresh_en    (thresh_en[0]),
        .i_thresh       (thresh[7:0]),
        .i_freeze       (1'b0),
        .o_roi_we       (roi_we),
        .o_roi_addr     (roi_addr),
        .o_roi_data     (roi_data),
        .o_frame_toggle (frame_tgl),
        .o_ready_bank   (ready_bank)
    );

    // Log ROI buffer writes and frame-done events (sampled after each rising edge)
    int  froi;
    logic frame_tgl_last = 1'b0;
    always @(posedge clk_pix) begin
        #2;
        if (froi != 0) begin
            if (roi_we === 1'b1) $fdisplay(froi, "w %h %h", roi_addr, roi_data);
            if (frame_tgl !== frame_tgl_last) begin
                $fdisplay(froi, "f");
                frame_tgl_last = frame_tgl;
            end
        end
    end

    initial begin
        int          fin, fout, n_read, n_cycles, found;
        logic [26:0] word;

        // Missing plusargs keep the default values above.
        found = $value$plusargs("gray%d",     gray_en);
        found = $value$plusargs("overlay%d",  overlay_en);
        found = $value$plusargs("roix%d",     roi_x0);
        found = $value$plusargs("roiy%d",     roi_y0);
        found = $value$plusargs("digit%d",    digit);
        found = $value$plusargs("inv%d",      invert);
        found = $value$plusargs("then%d",     thresh_en);
        found = $value$plusargs("thr%d",      thresh);
        $display("TB: gray=%0d overlay=%0d roi=(%0d,%0d) digit=%0d invert=%0d thresh_en=%0d thresh=%0d",
                 gray_en, overlay_en, roi_x0, roi_y0, digit, invert, thresh_en, thresh);

        fin  = $fopen("stream_in.txt",  "r");
        fout = $fopen("stream_out.txt", "w");
        froi = $fopen("roi_writes.txt", "w");
        if (fin == 0 || fout == 0 || froi == 0) $fatal(1, "TB: cannot open files");

        n_cycles = 0;
        // Drive one stream word per clock (change inputs on the falling edge,
        // so they are stable at the rising edge where the DUT samples them).
        while (!$feof(fin)) begin
            n_read = $fscanf(fin, "%h\n", word);
            if (n_read != 1) break;
            @(negedge clk_pix);
            in_vid = '{data: word[23:0], de: word[26], hs: word[25], vs: word[24]};
            @(posedge clk_pix);
            #1 $fdisplay(fout, "%h", {out_vid.de, out_vid.hs, out_vid.vs, out_vid.data});
            n_cycles++;
        end

        // Flush: blanking for LATENCY more clocks so the last pixels come out.
        repeat (LATENCY) begin
            @(negedge clk_pix);
            in_vid = '0;
            @(posedge clk_pix);
            #1 $fdisplay(fout, "%h", {out_vid.de, out_vid.hs, out_vid.vs, out_vid.data});
        end

        $fclose(fin);
        $fclose(fout);
        $fclose(froi);
        froi = 0;
        $display("TB: done, %0d input clocks", n_cycles);
        $finish;
    end

endmodule

`default_nettype wire
