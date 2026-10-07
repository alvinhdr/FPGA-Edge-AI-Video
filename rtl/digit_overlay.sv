// =============================================================================
// File   : digit_overlay.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Draw one big digit (8x8 font, scaled up by 2^SCALE_LOG2) on the
//          video at a fixed position. Latency: 1 clock.
//
// Example: SCALE_LOG2 = 3 -> each font pixel becomes 8x8 screen pixels,
//          so the digit is 64 x 64 screen pixels.
// The scale is a power of two, so "divide by scale" is just a right shift
// (no divider hardware needed).
// =============================================================================
`default_nettype none

module digit_overlay
    import video_pkg::*;
#(
    parameter int          X0         = 784,             // top-left corner of the digit
    parameter int          Y0         = 248,
    parameter int          SCALE_LOG2 = 3,               // 3 -> 8x scale -> 64x64 pixels
    parameter logic [23:0] COLOR      = COLOR_GREEN,
    parameter string       FONT_FILE  = "font_digits_8x8.mem"
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    input  wire  [POS_W-1:0] i_x,
    input  wire  [POS_W-1:0] i_y,
    input  wire  [3:0]       i_digit,  // digit to draw (0..9)
    input  wire              i_show,   // 0 = draw nothing
    output video_t           o_vid,
    output logic [POS_W-1:0] o_x,
    output logic [POS_W-1:0] o_y
);

    localparam int SIZE = 8 << SCALE_LOG2;   // digit size in screen pixels

    // Position inside the digit box (only meaningful when in_box = 1)
    logic             in_box;
    logic [POS_W-1:0] rel_x, rel_y;
    logic [2:0]       font_col, font_row;
    logic [7:0]       font_bits;
    logic             pixel_on;

    always_comb begin
        in_box   = (i_x >= X0) && (i_x < X0 + SIZE) && (i_y >= Y0) && (i_y < Y0 + SIZE);
        rel_x    = i_x - X0[POS_W-1:0];
        rel_y    = i_y - Y0[POS_W-1:0];
        font_col = rel_x[SCALE_LOG2 +: 3];   // = rel_x >> SCALE_LOG2 (0..7)
        font_row = rel_y[SCALE_LOG2 +: 3];
    end

    font_rom #(.FONT_FILE(FONT_FILE)) u_font (
        .i_digit (i_digit),
        .i_row   (font_row),
        .o_bits  (font_bits)
    );

    assign pixel_on = i_show && in_box && font_bits[3'd7 - font_col];

    always_ff @(posedge clk_pix) begin
        o_vid <= i_vid;
        o_x   <= i_x;
        o_y   <= i_y;
        if (i_vid.de && pixel_on) o_vid.data <= COLOR;
    end

endmodule

`default_nettype wire
