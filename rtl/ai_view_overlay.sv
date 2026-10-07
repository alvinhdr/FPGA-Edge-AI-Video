// =============================================================================
// File   : ai_view_overlay.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Draw the 28x28 "what the AI sees" image, scaled up by 2^SCALE_LOG2,
//          at a fixed place on the screen. Latency: 2 clocks.
//
//   clock t   : compute the RAM address from (x, y); the RAM reads it
//   clock t+1 : RAM data is ready; the video is delayed by one register
//   clock t+2 : output, with the gray AI pixel replacing the video pixel
//
// The RAM (preview buffer) is written by roi_capture in the same clock domain.
// Shown image = the previous frame's capture (the AI view is to the LEFT of the
// ROI, so on every line it is read before that line's ROI blocks are written).
// =============================================================================
`default_nettype none

module ai_view_overlay
    import video_pkg::*;
#(
    parameter int X0         = 256,   // top-left corner on screen
    parameter int Y0         = 248,
    parameter int GRID       = 28,
    parameter int SCALE_LOG2 = 3      // 3 -> 8x -> 224 x 224 pixels
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    input  wire  [POS_W-1:0] i_x,
    input  wire  [POS_W-1:0] i_y,
    input  wire              i_show,
    output video_t           o_vid,
    output logic [POS_W-1:0] o_x,
    output logic [POS_W-1:0] o_y,

    output logic [9:0]       o_ram_addr,   // to the preview RAM (1-clock read latency)
    input  wire  [7:0]       i_ram_data
);

    localparam int SIZE = GRID << SCALE_LOG2;

    logic             in_view;
    logic [POS_W-1:0] rel_x, rel_y;
    logic [4:0]       px, py;

    always_comb begin
        in_view    = (i_x >= X0) && (i_x < X0 + SIZE) && (i_y >= Y0) && (i_y < Y0 + SIZE);
        rel_x      = i_x - X0[POS_W-1:0];
        rel_y      = i_y - Y0[POS_W-1:0];
        px         = rel_x[SCALE_LOG2 +: 5];
        py         = rel_y[SCALE_LOG2 +: 5];
        o_ram_addr = 10'(py * GRID + px);
    end

    // Stage 1: wait for the RAM data
    video_t           vid1;
    logic [POS_W-1:0] x1, y1;
    logic             draw1;

    always_ff @(posedge clk_pix) begin
        vid1  <= i_vid;
        x1    <= i_x;
        y1    <= i_y;
        draw1 <= i_show && in_view && i_vid.de;
    end

    // Stage 2: output
    always_ff @(posedge clk_pix) begin
        o_vid <= vid1;
        o_x   <= x1;
        o_y   <= y1;
        if (draw1) o_vid.data <= pack_rgb(i_ram_data, i_ram_data, i_ram_data);
    end

endmodule

`default_nettype wire
