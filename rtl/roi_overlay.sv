// =============================================================================
// File   : roi_overlay.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Draw a colored square frame around the ROI (region of interest,
//          the area the AI looks at). Latency: 1 clock.
//
// The frame is drawn OUTSIDE the ROI (BORDER pixels thick), so the pixels
// inside the ROI - the ones the AI will read - are never covered by the box.
// The ROI position is an input (later an AXI-Lite register); the size is fixed.
// =============================================================================
`default_nettype none

module roi_overlay
    import video_pkg::*;
#(
    parameter int          ROI_SIZE = 224,           // ROI width = height in pixels
    parameter int          BORDER   = 3,             // frame thickness in pixels
    parameter logic [23:0] COLOR    = COLOR_GREEN
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    input  wire  [POS_W-1:0] i_x,
    input  wire  [POS_W-1:0] i_y,
    input  wire  [POS_W-1:0] i_roi_x0,   // left column of the ROI
    input  wire  [POS_W-1:0] i_roi_y0,   // top row of the ROI
    input  wire              i_show,     // 0 = draw nothing
    output video_t           o_vid,
    output logic [POS_W-1:0] o_x,
    output logic [POS_W-1:0] o_y
);

    // One extra bit so "x0 + size + border" cannot overflow.
    logic [POS_W:0] x, y, x0, y0;
    logic           in_outer, in_roi, on_frame;

    always_comb begin
        x  = {1'b0, i_x};
        y  = {1'b0, i_y};
        x0 = {1'b0, i_roi_x0};
        y0 = {1'b0, i_roi_y0};
        // "x + BORDER >= x0" instead of "x >= x0 - BORDER" avoids underflow near 0.
        in_outer = (x + BORDER >= x0) && (x < x0 + ROI_SIZE + BORDER) &&
                   (y + BORDER >= y0) && (y < y0 + ROI_SIZE + BORDER);
        in_roi   = (x >= x0) && (x < x0 + ROI_SIZE) &&
                   (y >= y0) && (y < y0 + ROI_SIZE);
        on_frame = i_show && in_outer && !in_roi;
    end

    always_ff @(posedge clk_pix) begin
        o_vid <= i_vid;
        o_x   <= i_x;
        o_y   <= i_y;
        if (i_vid.de && on_frame) o_vid.data <= COLOR;
    end

endmodule

`default_nettype wire
