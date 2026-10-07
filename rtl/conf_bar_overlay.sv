// =============================================================================
// File   : conf_bar_overlay.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Draw the CNN confidence as a horizontal bar. Latency: 1 clock.
//          Frame: gray outline, BAR_W x BAR_H pixels. Fill: green, width =
//          conf * BAR_W / 256 (BAR_W = 128 -> conf >> 1, so 255 -> 127 pixels).
// =============================================================================
`default_nettype none

module conf_bar_overlay
    import video_pkg::*;
#(
    parameter int          X0     = 784,
    parameter int          Y0     = 392,
    parameter int          BAR_W  = 128,           // must be 128 (fill = conf >> 1)
    parameter int          BAR_H  = 12,
    parameter logic [23:0] COLOR  = COLOR_GREEN,
    parameter logic [23:0] FRAME  = 24'h80_80_80   // gray (R=B=G)
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    input  wire  [POS_W-1:0] i_x,
    input  wire  [POS_W-1:0] i_y,
    input  wire              i_show,
    input  wire  [7:0]       i_conf,
    output video_t           o_vid
);

    logic             in_box, on_frame, on_fill;
    logic [POS_W-1:0] rel_x;

    always_comb begin
        in_box   = (i_x >= X0) && (i_x < X0 + BAR_W) && (i_y >= Y0) && (i_y < Y0 + BAR_H);
        rel_x    = i_x - X0[POS_W-1:0];
        on_frame = in_box && ((i_x == X0) || (i_x == X0 + BAR_W - 1) || (i_y == Y0) || (i_y == Y0 + BAR_H - 1));
        on_fill  = in_box && (rel_x < (i_conf >> 1));
    end

    always_ff @(posedge clk_pix) begin
        o_vid <= i_vid;
        if (i_vid.de && i_show) begin
            if      (on_fill)  o_vid.data <= COLOR;
            else if (on_frame) o_vid.data <= FRAME;
        end
    end

endmodule

`default_nettype wire
