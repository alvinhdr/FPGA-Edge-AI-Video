// =============================================================================
// File   : pix_pos_counter.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Find the (x, y) position of every visible pixel from the video
//          timing signals. Latency: 1 clock.
//
// How it works:
//   - Only DE (data enable) is used. DE is always active-high, but HSYNC/VSYNC
//     polarity changes between video modes, so DE is the most robust signal.
//   - x: 0 at the first visible pixel of a line (DE rising edge), +1 per pixel.
//   - y: +1 at each new line. A new FRAME is detected when DE stayed low for a
//     long time (vertical blanking). Horizontal blanking at 720p is 370 clocks,
//     vertical blanking is 30 lines (~49,500 clocks), so a threshold of
//     VBLANK_MIN clocks separates them safely.
//
// Output o_* is input i_* delayed by 1 clock, with x/y/sof for that same pixel.
// =============================================================================
`default_nettype none

module pix_pos_counter
    import video_pkg::*;
#(
    parameter int VBLANK_MIN = 4096   // DE-low clocks that mean "vertical blanking"
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    output video_t           o_vid,
    output logic [POS_W-1:0] o_x,
    output logic [POS_W-1:0] o_y,
    output logic             o_sof     // 1 on the first visible pixel of a frame
);

    localparam int GAP_W = $clog2(VBLANK_MIN + 1);

    logic [GAP_W-1:0] gap_cnt_q   = '0;    // clocks since DE was last high
    logic             new_frame_q = 1'b1;  // next line is the first line of a frame

    // o_vid.de is the DE of the previous clock, so (i_vid.de && !o_vid.de)
    // marks the first pixel of a line.
    always_ff @(posedge clk_pix) begin
        o_vid <= i_vid;
        o_sof <= 1'b0;

        if (i_vid.de) begin
            gap_cnt_q <= '0;
            if (!o_vid.de) begin
                // First pixel of a new line
                o_x <= '0;
                if (new_frame_q) begin
                    o_y         <= '0;
                    o_sof       <= 1'b1;
                    new_frame_q <= 1'b0;
                end else begin
                    o_y <= o_y + 1'b1;
                end
            end else begin
                o_x <= o_x + 1'b1;
            end
        end else begin
            if (gap_cnt_q < VBLANK_MIN[GAP_W-1:0]) begin
                gap_cnt_q <= gap_cnt_q + 1'b1;
            end else begin
                new_frame_q <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
