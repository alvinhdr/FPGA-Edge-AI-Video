// =============================================================================
// File   : top.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Board  : Digilent Zybo Z7-10
// Purpose: Top level. Phase 6 = full system: HDMI pass-through + pixel pipeline +
//          ROI capture + CNN accelerator (ai_core, clk_acc) + live result overlay.
//
//   Laptop --HDMI--> dvi2rgb --(RGB + sync, clk_pix 74.25 MHz)--> pixel_pipeline
//                                                        --> rgb2dvi --HDMI--> Monitor
//
//   - No frame buffer: pixels stream through with a 4-clock pipeline delay.
//   - clk_ref (200 MHz) is made from the 125 MHz board clock. dvi2rgb needs it
//     for its input delay calibration (IDELAYCTRL) and for the EDID emulator.
//   - The ARM (PS) is inside ps_bd (block design). In Phase 1 it only runs the
//     UART "hello" program; the video path does not depend on it.
//
// LEDs:
//   led[0] blinks : 125 MHz board clock (via PLL, clk_sys) is running
//   led[1] on     : 200 MHz reference clock is locked
//   led[2] on     : HDMI input is locked (dvi2rgb pLocked)
//   led[3] blinks : pixel clock from the laptop is running
//
// Switches:
//   sw[0] up : grayscale view of the whole picture
//   sw[1] up : hide the ROI box and the digit
// =============================================================================
`default_nettype none

module top #(
    // Number of parallel MACs in the CNN (1, 2, 4, 8 or 16). Set by scripts/build_hw.tcl
    // (second argument) for the Phase 7 speed-vs-area table; the demo uses 8.
    parameter int CNN_P = 8
) (
    // Board clock
    input  wire         sysclk,          // 125 MHz

    // HDMI RX (input from laptop)
    input  wire         hdmi_rx_clk_p,
    input  wire         hdmi_rx_clk_n,
    input  wire  [2:0]  hdmi_rx_p,
    input  wire  [2:0]  hdmi_rx_n,
    output wire         hdmi_rx_hpd,     // hot-plug detect: "a screen is connected"
    inout  wire         hdmi_rx_scl,     // DDC (I2C) clock, for EDID
    inout  wire         hdmi_rx_sda,     // DDC (I2C) data,  for EDID

    // HDMI TX (output to monitor)
    output wire         hdmi_tx_clk_p,
    output wire         hdmi_tx_clk_n,
    output wire  [2:0]  hdmi_tx_p,
    output wire  [2:0]  hdmi_tx_n,

    // Debug LEDs and switches
    output wire  [3:0]  led,
    input  wire  [1:0]  sw,

    // Zynq PS fixed pins (DDR memory and MIO). Connected to the ARM only.
    inout  wire  [14:0] DDR_addr,
    inout  wire  [2:0]  DDR_ba,
    inout  wire         DDR_cas_n,
    inout  wire         DDR_ck_n,
    inout  wire         DDR_ck_p,
    inout  wire         DDR_cke,
    inout  wire         DDR_cs_n,
    inout  wire  [3:0]  DDR_dm,
    inout  wire  [31:0] DDR_dq,
    inout  wire  [3:0]  DDR_dqs_n,
    inout  wire  [3:0]  DDR_dqs_p,
    inout  wire         DDR_odt,
    inout  wire         DDR_ras_n,
    inout  wire         DDR_reset_n,
    inout  wire         DDR_we_n,
    inout  wire         FIXED_IO_ddr_vrn,
    inout  wire         FIXED_IO_ddr_vrp,
    inout  wire  [53:0] FIXED_IO_mio,
    inout  wire         FIXED_IO_ps_clk,
    inout  wire         FIXED_IO_ps_porb,
    inout  wire         FIXED_IO_ps_srstb
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int SYS_BLINK_BIT = 26;   // 2^26 / 125 MHz   = 0.54 s (clk_sys) per LED toggle
    localparam int PIX_BLINK_BIT = 25;   // 2^25 / 74.25 MHz = 0.45 s per LED toggle

    // -------------------------------------------------------------------------
    // Clocks from the board oscillator (Clocking Wizard IP, PLL)
    //   clk_ref = 200 MHz for dvi2rgb, clk_sys = 125 MHz for our own slow logic.
    //   sysclk drives ONLY the PLL (see docs/TIMING.md, DRC REQP-1712).
    // -------------------------------------------------------------------------
    logic clk_ref;          // 200 MHz
    logic clk_sys;          // 125 MHz
    logic ref_locked;       // high when the PLL outputs are stable

    clk_wiz_ref u_clk_wiz_ref (
        .clk_in1  (sysclk),
        .clk_out1 (clk_ref),
        .clk_out2 (clk_sys),
        .locked   (ref_locked)
    );

    // -------------------------------------------------------------------------
    // HDMI input: TMDS -> parallel RGB (Digilent dvi2rgb)
    // -------------------------------------------------------------------------
    logic        clk_pix;           // recovered pixel clock (74.25 MHz at 720p)
    logic        pix_locked;        // high when the HDMI input is locked
    logic [23:0] rx_data;           // 24-bit pixel (Digilent channel order, see docs)
    logic        rx_de;             // data enable: 1 = visible pixel
    logic        rx_hsync;
    logic        rx_vsync;

    logic ddc_scl_i, ddc_scl_o, ddc_scl_t;
    logic ddc_sda_i, ddc_sda_o, ddc_sda_t;

    dvi2rgb_0 u_dvi2rgb (
        .TMDS_Clk_p    (hdmi_rx_clk_p),
        .TMDS_Clk_n    (hdmi_rx_clk_n),
        .TMDS_Data_p   (hdmi_rx_p),
        .TMDS_Data_n   (hdmi_rx_n),
        .RefClk        (clk_ref),
        .aRst_n        (ref_locked),     // hold in reset until clk_ref is stable
        .vid_pData     (rx_data),
        .vid_pVDE      (rx_de),
        .vid_pHSync    (rx_hsync),
        .vid_pVSync    (rx_vsync),
        .PixelClk      (clk_pix),
        .aPixelClkLckd (),               // deprecated, unused
        .pLocked       (pix_locked),
        .SDA_I         (ddc_sda_i),
        .SDA_O         (ddc_sda_o),
        .SDA_T         (ddc_sda_t),
        .SCL_I         (ddc_scl_i),
        .SCL_O         (ddc_scl_o),
        .SCL_T         (ddc_scl_t),
        .pRst_n        (1'b1)            // no extra synchronous reset
    );

    // DDC (I2C) pins are bidirectional: IOBUF = tri-state buffer.
    // T = 1 -> pin is released (input), T = 0 -> pin is driven with O.
    IOBUF u_iobuf_ddc_scl (.IO(hdmi_rx_scl), .I(ddc_scl_o), .T(ddc_scl_t), .O(ddc_scl_i));
    IOBUF u_iobuf_ddc_sda (.IO(hdmi_rx_sda), .I(ddc_sda_o), .T(ddc_sda_t), .O(ddc_sda_i));

    // Tell the laptop "a screen is connected" only after the EDID emulator
    // (clocked by clk_ref) is ready to answer.
    assign hdmi_rx_hpd = ref_locked;

    // -------------------------------------------------------------------------
    // Settings from the ARM (clk_acc) -> clk_pix, through a req/ack bus handshake
    // (multi-bit values must change all bits together; docs/CDC.md).
    // Before the ARM runs, clk_acc is stopped and the INIT values are used.
    // -------------------------------------------------------------------------
    localparam logic [10:0] ROI_X0_DEFAULT = 11'd528;   // ROI = x 528..751 (center of 1280)
    localparam logic [10:0] ROI_Y0_DEFAULT = 11'd248;   //       y 248..471 (center of 720)
    localparam int          CFG_W          = 33;
    // {roi_x0[10:0], roi_y0[10:0], invert, thresh_en, freeze, thresh[7:0]}
    localparam logic [CFG_W-1:0] CFG_INIT  = {ROI_X0_DEFAULT, ROI_Y0_DEFAULT, 1'b1, 1'b0, 1'b0, 8'd64};

    logic              clk_acc, rst_acc_n;
    logic              acc_invert, acc_thresh_en, acc_freeze;
    logic [7:0]        acc_thresh;
    logic [10:0]       acc_roi_x0, acc_roi_y0;
    logic [CFG_W-1:0]  cfg_pix;
    logic [10:0]       pix_roi_x0, pix_roi_y0;
    logic              pix_invert, pix_thresh_en, pix_freeze;
    logic [7:0]        pix_thresh;

    cdc_bus_sync #(.W(CFG_W), .INIT(CFG_INIT)) u_cfg_sync (
        .clk_src (clk_acc),
        .i_data  ({acc_roi_x0, acc_roi_y0, acc_invert, acc_thresh_en, acc_freeze, acc_thresh}),
        .clk_dst (clk_pix),
        .o_data  (cfg_pix)
    );
    assign {pix_roi_x0, pix_roi_y0, pix_invert, pix_thresh_en, pix_freeze, pix_thresh} = cfg_pix;

    // CNN result (clk_acc) -> clk_pix, same req/ack handshake: {valid, digit, conf} = 13 bits
    logic        acc_res_valid, pix_res_valid;
    logic [3:0]  acc_digit, pix_digit;
    logic [7:0]  acc_conf, pix_conf;

    cdc_bus_sync #(.W(13), .INIT('0)) u_result_sync (
        .clk_src (clk_acc),
        .i_data  ({acc_res_valid, acc_digit, acc_conf}),
        .clk_dst (clk_pix),
        .o_data  ({pix_res_valid, pix_digit, pix_conf})
    );

    // -------------------------------------------------------------------------
    // Pixel pipeline (all on clk_pix): position, gray view, ROI box, AI view,
    // digit, and the ROI capture (224x224 -> 28x28)
    // -------------------------------------------------------------------------
    // Switches are asynchronous to clk_pix -> 2-flop synchronizers (docs/CDC.md)
    logic sw_gray_pix, sw_hide_pix;
    cdc_sync_2ff u_sync_sw0 (.clk_dst(clk_pix), .d_async(sw[0]), .q_sync(sw_gray_pix));
    cdc_sync_2ff u_sync_sw1 (.clk_dst(clk_pix), .d_async(sw[1]), .q_sync(sw_hide_pix));

    video_pkg::video_t rx_vid, tx_vid;
    assign rx_vid = '{data: rx_data, de: rx_de, hs: rx_hsync, vs: rx_vsync};

    logic        roi_we, frame_toggle_pix, ready_bank_pix;
    logic [10:0] roi_waddr;
    logic [7:0]  roi_wdata;

    pixel_pipeline u_pixel_pipeline (
        .clk_pix        (clk_pix),
        .i_vid          (rx_vid),
        .o_vid          (tx_vid),
        .i_gray_en      (sw_gray_pix),
        .i_overlay_en   (~sw_hide_pix),
        .i_roi_x0       (pix_roi_x0),
        .i_roi_y0       (pix_roi_y0),
        .i_digit        (pix_digit),
        .i_conf         (pix_conf),
        .i_result_valid (pix_res_valid),
        .i_invert       (pix_invert),
        .i_thresh_en    (pix_thresh_en),
        .i_thresh       (pix_thresh),
        .i_freeze       (pix_freeze),
        .o_roi_we       (roi_we),
        .o_roi_addr     (roi_waddr),
        .o_roi_data     (roi_wdata),
        .o_frame_toggle (frame_toggle_pix),
        .o_ready_bank   (ready_bank_pix)
    );

    // -------------------------------------------------------------------------
    // ROI buffer: dual-clock block RAM, 2 banks x 1024 bytes (784 used).
    // Port A: written by roi_capture (clk_pix). Port B: read by AXI-Lite (clk_acc).
    // The two ports never touch the same bank at the same time (docs/CDC.md).
    // -------------------------------------------------------------------------
    logic [10:0] roi_raddr;
    logic [7:0]  roi_rdata;

    ram_tdp #(.DW(8), .AW(11)) u_roi_buffer (
        .clk_a  (clk_pix),
        .we_a   (roi_we),
        .addr_a (roi_waddr),
        .din_a  (roi_wdata),
        .dout_a (),
        .clk_b  (clk_acc),
        .we_b   (1'b0),          // read-only from clk_acc (test images use the inject RAM)
        .addr_b (roi_raddr),
        .din_b  (8'd0),
        .dout_b (roi_rdata)
    );

    // Frame-done event and ready bank: clk_pix -> clk_acc
    logic frame_pulse_acc, ready_bank_acc;
    cdc_pulse_sync u_frame_sync (.clk_dst(clk_acc), .i_src_toggle(frame_toggle_pix), .o_dst_pulse(frame_pulse_acc));
    cdc_sync_2ff   u_bank_sync  (.clk_dst(clk_acc), .d_async(ready_bank_pix), .q_sync(ready_bank_acc));

    logic [23:0] tx_data;
    logic        tx_de;
    logic        tx_hsync;
    logic        tx_vsync;

    assign tx_data  = tx_vid.data;
    assign tx_de    = tx_vid.de;
    assign tx_hsync = tx_vid.hs;
    assign tx_vsync = tx_vid.vs;

    // -------------------------------------------------------------------------
    // HDMI output: parallel RGB -> TMDS (Digilent rgb2dvi)
    // rgb2dvi makes its own 5x serial clock from clk_pix with an MMCM.
    // -------------------------------------------------------------------------
    rgb2dvi_0 u_rgb2dvi (
        .TMDS_Clk_p  (hdmi_tx_clk_p),
        .TMDS_Clk_n  (hdmi_tx_clk_n),
        .TMDS_Data_p (hdmi_tx_p),
        .TMDS_Data_n (hdmi_tx_n),
        .aRst_n      (pix_locked),       // hold in reset until the input is locked
        .vid_pData   (tx_data),
        .vid_pVDE    (tx_de),
        .vid_pHSync  (tx_hsync),
        .vid_pVSync  (tx_vsync),
        .PixelClk    (clk_pix)
    );

    // -------------------------------------------------------------------------
    // Zynq Processing System (ARM). Block design "ps_bd": PS + AXI-Lite master
    // port (M_AXI_LITE, base 0x43C0_0000) + clk_acc (100 MHz) and its reset.
    // -------------------------------------------------------------------------
    logic [31:0] axi_awaddr, axi_wdata, axi_araddr, axi_rdata;
    logic [3:0]  axi_wstrb;
    logic [1:0]  axi_bresp, axi_rresp;
    logic        axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
    logic        axi_arvalid, axi_arready, axi_rvalid, axi_rready;

    ps_bd_wrapper u_ps (
        .DDR_addr            (DDR_addr),
        .DDR_ba              (DDR_ba),
        .DDR_cas_n           (DDR_cas_n),
        .DDR_ck_n            (DDR_ck_n),
        .DDR_ck_p            (DDR_ck_p),
        .DDR_cke             (DDR_cke),
        .DDR_cs_n            (DDR_cs_n),
        .DDR_dm              (DDR_dm),
        .DDR_dq              (DDR_dq),
        .DDR_dqs_n           (DDR_dqs_n),
        .DDR_dqs_p           (DDR_dqs_p),
        .DDR_odt             (DDR_odt),
        .DDR_ras_n           (DDR_ras_n),
        .DDR_reset_n         (DDR_reset_n),
        .DDR_we_n            (DDR_we_n),
        .FIXED_IO_ddr_vrn    (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp    (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio        (FIXED_IO_mio),
        .FIXED_IO_ps_clk     (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb    (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb   (FIXED_IO_ps_srstb),
        .M_AXI_LITE_araddr   (axi_araddr),
        .M_AXI_LITE_arprot   (),
        .M_AXI_LITE_arready  (axi_arready),
        .M_AXI_LITE_arvalid  (axi_arvalid),
        .M_AXI_LITE_awaddr   (axi_awaddr),
        .M_AXI_LITE_awprot   (),
        .M_AXI_LITE_awready  (axi_awready),
        .M_AXI_LITE_awvalid  (axi_awvalid),
        .M_AXI_LITE_bready   (axi_bready),
        .M_AXI_LITE_bresp    (axi_bresp),
        .M_AXI_LITE_bvalid   (axi_bvalid),
        .M_AXI_LITE_rdata    (axi_rdata),
        .M_AXI_LITE_rready   (axi_rready),
        .M_AXI_LITE_rresp    (axi_rresp),
        .M_AXI_LITE_rvalid   (axi_rvalid),
        .M_AXI_LITE_wdata    (axi_wdata),
        .M_AXI_LITE_wready   (axi_wready),
        .M_AXI_LITE_wstrb    (axi_wstrb),
        .M_AXI_LITE_wvalid   (axi_wvalid),
        .clk_acc             (clk_acc),
        .rst_acc_n           (rst_acc_n)
    );

    // Accelerator clock domain: AXI-Lite registers + CNN + inject RAM (rtl/ai_core.sv).
    // Only the low 16 address bits are decoded (64 KB window at 0x43C0_0000).
    // Weight/bias ROM files for this P (written by ml/export.py)
    localparam string CNN_WROM = (CNN_P == 1) ? "wrom_p1.mem" : (CNN_P == 2) ? "wrom_p2.mem" :
                                 (CNN_P == 4) ? "wrom_p4.mem" : (CNN_P == 16) ? "wrom_p16.mem" : "wrom_p8.mem";
    localparam string CNN_BROM = (CNN_P == 1) ? "brom_p1.mem" : (CNN_P == 2) ? "brom_p2.mem" :
                                 (CNN_P == 4) ? "brom_p4.mem" : (CNN_P == 16) ? "brom_p16.mem" : "brom_p8.mem";

    ai_core #(.P(CNN_P), .WROM_FILE(CNN_WROM), .BROM_FILE(CNN_BROM)) u_ai (
        .clk            (clk_acc),
        .rst_n          (rst_acc_n),
        .s_axi_awaddr   (axi_awaddr[15:0]),
        .s_axi_awvalid  (axi_awvalid),
        .s_axi_awready  (axi_awready),
        .s_axi_wdata    (axi_wdata),
        .s_axi_wstrb    (axi_wstrb),
        .s_axi_wvalid   (axi_wvalid),
        .s_axi_wready   (axi_wready),
        .s_axi_bresp    (axi_bresp),
        .s_axi_bvalid   (axi_bvalid),
        .s_axi_bready   (axi_bready),
        .s_axi_araddr   (axi_araddr[15:0]),
        .s_axi_arvalid  (axi_arvalid),
        .s_axi_arready  (axi_arready),
        .s_axi_rdata    (axi_rdata),
        .s_axi_rresp    (axi_rresp),
        .s_axi_rvalid   (axi_rvalid),
        .s_axi_rready   (axi_rready),
        .o_roi_addr     (roi_raddr),
        .i_roi_data     (roi_rdata),
        .i_frame_pulse  (frame_pulse_acc),
        .i_ready_bank   (ready_bank_acc),
        .o_invert       (acc_invert),
        .o_thresh_en    (acc_thresh_en),
        .o_freeze       (acc_freeze),
        .o_thresh       (acc_thresh),
        .o_roi_x0       (acc_roi_x0),
        .o_roi_y0       (acc_roi_y0),
        .o_result_valid (acc_res_valid),
        .o_digit        (acc_digit),
        .o_conf         (acc_conf)
    );

    // -------------------------------------------------------------------------
    // Debug LEDs
    // -------------------------------------------------------------------------
    logic [SYS_BLINK_BIT:0] sys_cnt_q = '0;
    logic [PIX_BLINK_BIT:0] pix_cnt_q = '0;
    logic                   pix_locked_sys;

    always_ff @(posedge clk_sys)  sys_cnt_q <= sys_cnt_q + 1'b1;
    always_ff @(posedge clk_pix) pix_cnt_q <= pix_cnt_q + 1'b1;

    // pix_locked comes from the pixel clock domain -> synchronize to clk_sys.
    cdc_sync_2ff u_sync_pix_locked (
        .clk_dst (clk_sys),
        .d_async (pix_locked),
        .q_sync  (pix_locked_sys)
    );

    assign led[0] = sys_cnt_q[SYS_BLINK_BIT];
    assign led[1] = ref_locked;
    assign led[2] = pix_locked_sys;
    assign led[3] = pix_cnt_q[PIX_BLINK_BIT];

endmodule

`default_nettype wire
