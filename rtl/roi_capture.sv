// =============================================================================
// File   : roi_capture.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Turn the 224x224 ROI of the live video into the 28x28 uint8 CNN input,
//          in the pixel clock domain, while the pixels stream by (no frame buffer).
//          Implements docs/QUANTIZATION.md section 8:
//
//            g     = (77R + 150G + 29B) >> 8
//            g_inv = invert ? 255 - g : g
//            avg   = (sum of the 8x8 block + 32) >> 6
//            x_q   = (thresh_en && avg < T) ? 0 : avg
//
// How the 8x8 average works without storing the picture:
//   - Horizontal: 8 neighbouring pixels of one line are summed in hsum_q.
//   - Vertical: that 8-pixel sum is added to col_acc[bx] (one accumulator per
//     block column, 28 of them). After the 8th line of a block row, each
//     col_acc[bx] holds the sum of a full 8x8 block -> one output pixel.
//   So only 28 x 14 bits of storage are needed, not 224 x 224 pixels.
//
// Output: one write per finished block, into a 2-bank buffer
//   o_addr = {bank, index}, index = by * 28 + bx (0..783).
// After the last block of a frame (index 783) the bank flips and o_frame_toggle
// toggles (an event for cdc_pulse_sync). o_ready_bank = the bank that holds the
// newest COMPLETE image; the other bank is the one being written.
// i_freeze = 1 stops the bank flips, so the ready bank stays stable for a slow
// reader (the ARM dumping it over UART).
//
// Settings are taken at the start of each frame (i_sof), so a change never mixes
// two settings inside one captured image. Latency is irrelevant here (side branch).
// =============================================================================
`default_nettype none

module roi_capture
    import video_pkg::*;
#(
    parameter int ROI_SIZE = 224,
    parameter int BLK_LOG2 = 3            // 8x8 blocks
) (
    input  wire              clk_pix,
    input  video_t           i_vid,       // from pix_pos_counter (original colors)
    input  wire  [POS_W-1:0] i_x,
    input  wire  [POS_W-1:0] i_y,
    input  wire              i_sof,

    input  wire  [POS_W-1:0] i_roi_x0,
    input  wire  [POS_W-1:0] i_roi_y0,
    input  wire              i_invert,
    input  wire              i_thresh_en,
    input  wire  [7:0]       i_thresh,
    input  wire              i_freeze,

    output logic             o_we,
    output logic [10:0]      o_addr,      // {bank, 10-bit index}
    output logic [7:0]       o_data,
    output logic             o_frame_toggle,
    output logic             o_ready_bank
);

    localparam int GRID   = ROI_SIZE >> BLK_LOG2;   // 28
    localparam int LAST   = GRID - 1;               // 27
    localparam int HSUM_W = 8 + BLK_LOG2;           // 11 bits: 8 x 255
    localparam int VSUM_W = 8 + 2 * BLK_LOG2;       // 14 bits: 64 x 255

    // ---- settings, captured at the start of each frame ----------------------
    logic [POS_W-1:0] x0_q = '0, y0_q = '0;
    logic             inv_q = 1'b0, then_q = 1'b0, frz_q = 1'b0;
    logic [7:0]       thr_q = '0;
    logic [POS_W-1:0] x0, y0;
    logic             inv;

    always_ff @(posedge clk_pix) begin
        if (i_sof) begin
            x0_q   <= i_roi_x0;
            y0_q   <= i_roi_y0;
            inv_q  <= i_invert;
            then_q <= i_thresh_en;
            thr_q  <= i_thresh;
            frz_q  <= i_freeze;
        end
    end

    // On the sof clock itself use the new values directly
    assign x0  = i_sof ? i_roi_x0 : x0_q;
    assign y0  = i_sof ? i_roi_y0 : y0_q;
    assign inv = i_sof ? i_invert : inv_q;

    // ---- stage 0 (combinational): inside ROI? gray value --------------------
    logic [POS_W:0] xe, ye, x0e, y0e;
    logic           in_roi;
    logic [7:0]     gray, g_in;

    rgb2gray u_gray (.i_data(i_vid.data), .o_gray(gray));

    always_comb begin
        xe  = {1'b0, i_x};
        ye  = {1'b0, i_y};
        x0e = {1'b0, x0};
        y0e = {1'b0, y0};
        in_roi = i_vid.de && (xe >= x0e) && (xe < x0e + ROI_SIZE) &&
                             (ye >= y0e) && (ye < y0e + ROI_SIZE);
        g_in = inv ? (8'd255 - gray) : gray;
    end

    // ---- stage 1: registered ROI pixel ---------------------------------------
    logic       v1 = 1'b0;
    logic [7:0] rx1, ry1, g1;

    always_ff @(posedge clk_pix) begin
        v1  <= in_roi;
        rx1 <= 8'(i_x - x0);
        ry1 <= 8'(i_y - y0);
        g1  <= g_in;
    end

    // ---- horizontal 8-pixel sum and vertical block accumulation ------------
    logic [HSUM_W-1:0] hsum_q = '0, hsum_next;
    logic [VSUM_W-1:0] col_acc [GRID];
    logic [VSUM_W-1:0] vsum;
    logic [4:0]        bx, by;
    logic              col_done, first_line, last_line;

    initial for (int i = 0; i < GRID; i++) col_acc[i] = '0;

    always_comb begin
        hsum_next  = (rx1[BLK_LOG2-1:0] == '0) ? HSUM_W'(g1) : hsum_q + g1;
        bx         = rx1[BLK_LOG2 +: 5];
        by         = ry1[BLK_LOG2 +: 5];
        col_done   = v1 && (rx1[BLK_LOG2-1:0] == '1);   // 8th pixel of a block column
        first_line = (ry1[BLK_LOG2-1:0] == '0);
        last_line  = (ry1[BLK_LOG2-1:0] == '1);
        vsum       = first_line ? VSUM_W'(hsum_next) : col_acc[bx] + hsum_next;
    end

    always_ff @(posedge clk_pix) begin
        if (v1)       hsum_q      <= hsum_next;
        if (col_done) col_acc[bx] <= vsum;
    end

    // ---- stage 2: average, threshold, write ----------------------------------
    logic       we2 = 1'b0, last2 = 1'b0;
    logic [9:0] idx2;
    logic [7:0] data2;
    logic [7:0] avg;

    assign avg = 8'((vsum + (VSUM_W'(1) << (2 * BLK_LOG2 - 1))) >> (2 * BLK_LOG2));

    always_ff @(posedge clk_pix) begin
        we2 <= col_done && last_line;
        if (col_done && last_line) begin
            idx2  <= 10'(by * GRID + bx);
            data2 <= (then_q && (avg < thr_q)) ? 8'd0 : avg;
            last2 <= (by == LAST) && (bx == LAST);
        end
    end

    // ---- bank control and frame-done event -----------------------------------
    logic wr_bank_q = 1'b0, ready_bank_q = 1'b1, tgl_q = 1'b0;

    always_ff @(posedge clk_pix) begin
        if (we2 && last2 && !frz_q) begin
            ready_bank_q <= wr_bank_q;
            wr_bank_q    <= ~wr_bank_q;
            tgl_q        <= ~tgl_q;
        end
    end

    assign o_we           = we2;
    assign o_addr         = {wr_bank_q, idx2};
    assign o_data         = data2;
    assign o_frame_toggle = tgl_q;
    assign o_ready_bank   = ready_bank_q;

endmodule

`default_nettype wire
