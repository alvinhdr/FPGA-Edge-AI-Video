// =============================================================================
// File   : top.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Board  : Digilent Zybo Z7-10
// Purpose: Top level. Phase 1 = HDMI pass-through.
//
//   Laptop --HDMI--> dvi2rgb --(RGB + sync, clk_pix 74.25 MHz)--> rgb2dvi --HDMI--> Monitor
//
//   - No frame buffer: pixels go straight from input to output.
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
// =============================================================================
`default_nettype none

module top (
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

    // Debug LEDs
    output wire  [3:0]  led,

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
    // Pixel pipeline (Phase 1: straight wire, no processing)
    // Phase 2+ will insert overlay / ROI modules here, all on clk_pix.
    // -------------------------------------------------------------------------
    logic [23:0] tx_data;
    logic        tx_de;
    logic        tx_hsync;
    logic        tx_vsync;

    assign tx_data  = rx_data;
    assign tx_de    = rx_de;
    assign tx_hsync = rx_hsync;
    assign tx_vsync = rx_vsync;

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
    // Zynq Processing System (ARM). Block design "ps_bd".
    // -------------------------------------------------------------------------
    ps_bd_wrapper u_ps (
        .DDR_addr          (DDR_addr),
        .DDR_ba            (DDR_ba),
        .DDR_cas_n         (DDR_cas_n),
        .DDR_ck_n          (DDR_ck_n),
        .DDR_ck_p          (DDR_ck_p),
        .DDR_cke           (DDR_cke),
        .DDR_cs_n          (DDR_cs_n),
        .DDR_dm            (DDR_dm),
        .DDR_dq            (DDR_dq),
        .DDR_dqs_n         (DDR_dqs_n),
        .DDR_dqs_p         (DDR_dqs_p),
        .DDR_odt           (DDR_odt),
        .DDR_ras_n         (DDR_ras_n),
        .DDR_reset_n       (DDR_reset_n),
        .DDR_we_n          (DDR_we_n),
        .FIXED_IO_ddr_vrn  (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp  (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio      (FIXED_IO_mio),
        .FIXED_IO_ps_clk   (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb  (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb (FIXED_IO_ps_srstb)
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
