// =============================================================================
// File   : pixel_pipeline.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: All pixel processing between the HDMI input and the HDMI output,
//          in the pixel clock domain (no frame buffer).
//
//   i_vid -> [1] pix_pos_counter -> [2] gray view -> [3] roi_overlay (green box)
//         -> [4,5] ai_view_overlay (28x28 AI input, 8x) -> [6] digit_overlay (CNN result)
//         -> [7] conf_bar_overlay -> o_vid
//                |
//                +-> roi_capture (side branch, original colors):
//                    224x224 ROI -> gray/invert/8x8 average/threshold -> 28x28
//                    -> o_roi_* writes (2-bank ROI buffer in top, read by clk_acc)
//                    -> preview RAM (here, read by ai_view_overlay)
//
//   LATENCY = 7 pixel clocks (~94 ns at 74.25 MHz). DE/HS/VS go through the same
//   registers as the pixel data, so they stay aligned.
// =============================================================================
`default_nettype none

module pixel_pipeline
    import video_pkg::*;
#(
    parameter int    ROI_SIZE         = 224,
    parameter int    DIGIT_X          = 784,
    parameter int    DIGIT_Y          = 248,
    parameter int    DIGIT_SCALE_LOG2 = 4,      // 4 -> 16x scale -> 128x128 pixel digit
    parameter int    AIV_X            = 256,    // AI view: 224x224 at the left of the ROI
    parameter int    AIV_Y            = 248,
    parameter int    BAR_Y            = 392,    // confidence bar under the 128x128 digit
    parameter string FONT_FILE        = "font_digits_8x8.mem"
) (
    input  wire              clk_pix,
    input  video_t           i_vid,
    output video_t           o_vid,

    // Configuration (clk_pix domain)
    input  wire              i_gray_en,     // 1 = show the whole picture in grayscale
    input  wire              i_overlay_en,  // 1 = draw box, AI view and digit
    input  wire  [POS_W-1:0] i_roi_x0,
    input  wire  [POS_W-1:0] i_roi_y0,
    input  wire  [3:0]       i_digit,       // CNN result digit, drawn next to the box
    input  wire  [7:0]       i_conf,        // CNN confidence 0..255 (bar under the digit)
    input  wire              i_result_valid,// 0 = no result yet: draw no digit and no bar
    input  wire              i_invert,      // ROI preprocessing (docs/QUANTIZATION.md section 8)
    input  wire              i_thresh_en,
    input  wire  [7:0]       i_thresh,
    input  wire              i_freeze,      // 1 = keep the ready ROI bank stable

    // ROI buffer write port (to the dual-clock RAM in top) and status
    output logic             o_roi_we,
    output logic [10:0]      o_roi_addr,    // {bank, index}
    output logic [7:0]       o_roi_data,
    output logic             o_frame_toggle,
    output logic             o_ready_bank
);

    localparam int LATENCY = 7;   // documented for testbenches (see tb/)

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

    // ---- Side branch: ROI capture ----------------------------------------
    roi_capture #(.ROI_SIZE(ROI_SIZE)) u_capture (
        .clk_pix        (clk_pix),
        .i_vid          (s1_vid),
        .i_x            (s1_x),
        .i_y            (s1_y),
        .i_sof          (s1_sof),
        .i_roi_x0       (i_roi_x0),
        .i_roi_y0       (i_roi_y0),
        .i_invert       (i_invert),
        .i_thresh_en    (i_thresh_en),
        .i_thresh       (i_thresh),
        .i_freeze       (i_freeze),
        .o_we           (o_roi_we),
        .o_addr         (o_roi_addr),
        .o_data         (o_roi_data),
        .o_frame_toggle (o_frame_toggle),
        .o_ready_bank   (o_ready_bank)
    );

    // Preview RAM: same data as the ROI buffer, single bank, both ports on clk_pix
    logic [9:0] prev_raddr;
    logic [7:0] prev_rdata;

    ram_tdp #(.DW(8), .AW(10)) u_preview_ram (
        .clk_a  (clk_pix),
        .we_a   (o_roi_we),
        .addr_a (o_roi_addr[9:0]),
        .din_a  (o_roi_data),
        .dout_a (),
        .clk_b  (clk_pix),
        .we_b   (1'b0),
        .addr_b (prev_raddr),
        .din_b  (8'd0),
        .dout_b (prev_rdata)
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

    // ---- Stages 4-5: AI view -------------------------------------------------
    video_t           s5_vid;
    logic [POS_W-1:0] s5_x, s5_y;

    ai_view_overlay #(.X0(AIV_X), .Y0(AIV_Y)) u_aiview (
        .clk_pix    (clk_pix),
        .i_vid      (s3_vid),
        .i_x        (s3_x),
        .i_y        (s3_y),
        .i_show     (i_overlay_en),
        .o_vid      (s5_vid),
        .o_x        (s5_x),
        .o_y        (s5_y),
        .o_ram_addr (prev_raddr),
        .i_ram_data (prev_rdata)
    );

    // ---- Stage 6: digit (CNN result) --------------------------------------------
    video_t           s6_vid;
    logic [POS_W-1:0] s6_x, s6_y;

    digit_overlay #(
        .X0         (DIGIT_X),
        .Y0         (DIGIT_Y),
        .SCALE_LOG2 (DIGIT_SCALE_LOG2),
        .FONT_FILE  (FONT_FILE)
    ) u_digit (
        .clk_pix (clk_pix),
        .i_vid   (s5_vid),
        .i_x     (s5_x),
        .i_y     (s5_y),
        .i_digit (i_digit),
        .i_show  (i_overlay_en && i_result_valid),
        .o_vid   (s6_vid),
        .o_x     (s6_x),
        .o_y     (s6_y)
    );

    // ---- Stage 7: confidence bar -------------------------------------------------
    conf_bar_overlay #(.X0(DIGIT_X), .Y0(BAR_Y)) u_bar (
        .clk_pix (clk_pix),
        .i_vid   (s6_vid),
        .i_x     (s6_x),
        .i_y     (s6_y),
        .i_show  (i_overlay_en && i_result_valid),
        .i_conf  (i_conf),
        .o_vid   (o_vid)
    );

endmodule

`default_nettype wire
