// =============================================================================
// File   : pixel_pipeline.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: All pixel processing between the HDMI input and the HDMI output,
//          in the pixel clock domain. Phase 2 version (no AI yet):
//
//   i_vid -> [1] pix_pos_counter -> [2] gray view -> [3] roi_overlay
//         -> [4] digit_overlay -> o_vid
//
//   Each stage is 1 clock, so LATENCY = 4 pixel clocks (~54 ns at 74.25 MHz).
//   The timing signals (DE, HS, VS) go through the same registers, so they
//   stay aligned with the pixel data. No frame buffer.
// =============================================================================
`default_nettype none

module pixel_pipeline
    import video_pkg::*;
#(
    parameter int    ROI_SIZE   = 224,
    parameter int    DIGIT_X    = 784,
    parameter int    DIGIT_Y    = 248,
    parameter int    DIGIT_SCALE_LOG2 = 4,      // 4 -> 16x scale -> 128x128 pixel digit
    parameter string FONT_FILE  = "font_digits_8x8.mem"
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    output video_t           o_vid,

    // Configuration (static for now; AXI-Lite registers in a later phase)
    input  wire              i_gray_en,   // 1 = show the whole picture in grayscale
    input  wire              i_overlay_en,// 1 = draw the box and the digit
    input  wire  [POS_W-1:0] i_roi_x0,
    input  wire  [POS_W-1:0] i_roi_y0,
    input  wire  [3:0]       i_digit      // digit to draw next to the box
);

    localparam int LATENCY = 4;   // documented for testbenches (see tb/)

    // ---- Stage 1: pixel position ----------------------------------------
    video_t           s1_vid;
    logic [POS_W-1:0] s1_x, s1_y;
    logic             s1_sof;

    pix_pos_counter u_pos (
        .clk_pix (clk_pix),
        .i_vid   (i_vid),
        .o_vid   (s1_vid),
        .o_x     (s1_x),
        .o_y     (s1_y),
        .o_sof   (s1_sof)
    );

    // ---- Stage 2: optional grayscale view --------------------------------
    video_t           s2_vid;
    logic [POS_W-1:0] s2_x, s2_y;
    logic [7:0]       s1_gray;

    rgb2gray u_gray (
        .i_data (s1_vid.data),
        .o_gray (s1_gray)
    );

    always_ff @(posedge clk_pix) begin
        s2_vid <= s1_vid;
        s2_x   <= s1_x;
        s2_y   <= s1_y;
        if (i_gray_en) s2_vid.data <= pack_rgb(s1_gray, s1_gray, s1_gray);
    end

    // ---- Stage 3: ROI box --------------------------------------------------
    video_t           s3_vid;
    logic [POS_W-1:0] s3_x, s3_y;

    roi_overlay #(.ROI_SIZE(ROI_SIZE)) u_roi (
        .clk_pix  (clk_pix),
        .i_vid    (s2_vid),
        .i_x      (s2_x),
        .i_y      (s2_y),
        .i_roi_x0 (i_roi_x0),
        .i_roi_y0 (i_roi_y0),
        .i_show   (i_overlay_en),
        .o_vid    (s3_vid),
        .o_x      (s3_x),
        .o_y      (s3_y)
    );

    // ---- Stage 4: digit ----------------------------------------------------
    digit_overlay #(
        .X0        (DIGIT_X),
        .Y0        (DIGIT_Y),
        .SCALE_LOG2(DIGIT_SCALE_LOG2),
        .FONT_FILE (FONT_FILE)
    ) u_digit (
        .clk_pix (clk_pix),
        .i_vid   (s3_vid),
        .i_x     (s3_x),
        .i_y     (s3_y),
        .i_digit (i_digit),
        .i_show  (i_overlay_en),
        .o_vid   (o_vid),
        .o_x     (),
        .o_y     ()
    );

endmodule

`default_nettype wire
