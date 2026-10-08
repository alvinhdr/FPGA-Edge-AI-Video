// =============================================================================
// File   : ai_core.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Everything in the accelerator clock domain (clk_acc, 100 MHz):
//            - AXI-Lite registers for the ARM (axil_regs)
//            - the CNN accelerator (cnn_top)
//            - the inject RAM (test images written by the ARM)
//            - start logic: run the CNN on every new ROI frame (auto) or on request
//            - sharing of ROI-buffer port B between the CNN and AXI readback
//            - result registers (digit, confidence, valid, cycles, count)
//
//   Auto mode: frame-done pulse (from clk_pix, already synchronized) -> start, if
//   cnn_enable = 1, inject_mode = 0 and the CNN is idle. The CNN reads the READY
//   bank, latched at start (the pixel side writes the other bank; the CNN needs
//   ~0.24 ms, the next bank flip is ~16.7 ms later).
//   Port B of the ROI buffer belongs to the CNN while it runs, else to AXI readback.
//   (The ARM capture program turns cnn_enable off while it reads the ROI.)
// =============================================================================
`default_nettype none

module ai_core #(
    parameter int    P         = 8,
    parameter string WROM_FILE = "wrom_p8.mem",
    parameter string BROM_FILE = "brom_p8.mem"
) (
    input  wire         clk,
    input  wire         rst_n,

    // AXI4-Lite slave (from the PS)
    input  wire  [15:0] s_axi_awaddr,
    input  wire         s_axi_awvalid,
    output logic        s_axi_awready,
    input  wire  [31:0] s_axi_wdata,
    input  wire  [3:0]  s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire  [15:0] s_axi_araddr,
    input  wire         s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  wire         s_axi_rready,

    // ROI buffer port B (dual-clock RAM in top), 1-clock read latency
    output logic [10:0] o_roi_addr,
    input  wire  [7:0]  i_roi_data,

    // From the pixel domain (already synchronized to clk)
    input  wire         i_frame_pulse,
    input  wire         i_ready_bank,

    // Settings for the pixel domain (crossed by cdc_bus_sync in top)
    output logic        o_invert,
    output logic        o_thresh_en,
    output logic        o_freeze,
    output logic [7:0]  o_thresh,
    output logic [10:0] o_roi_x0,
    output logic [10:0] o_roi_y0,

    // Result for the pixel domain (crossed by cdc_bus_sync in top)
    output logic        o_result_valid,
    output wire         o_overlay_valid,     // o_result_valid && conf >= CONF_MIN (drives the video overlay)
    output logic [3:0]  o_digit,
    output logic [7:0]  o_conf
);

    // ---- AXI-Lite registers --------------------------------------------------------
    logic               cnn_enable, inject_mode, cnn_start_req;
    logic [7:0]         conf_min;
    logic               inj_we;
    logic [9:0]         inj_waddr;
    logic [7:0]         inj_wdata;
    logic [10:0]        axi_roi_addr;
    logic               busy_q;
    logic [31:0]        cycles, count_q;
    logic signed [31:0] fc_acc [10];

    axil_regs u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .o_invert(o_invert), .o_thresh_en(o_thresh_en), .o_freeze(o_freeze),
        .o_cnn_enable(cnn_enable), .o_inject_mode(inject_mode), .o_thresh(o_thresh), .o_conf_min(conf_min),
        .o_roi_x0(o_roi_x0), .o_roi_y0(o_roi_y0), .o_cnn_start(cnn_start_req),
        .i_frame_pulse(i_frame_pulse), .i_ready_bank(i_ready_bank), .i_cnn_busy(busy_q),
        .i_result_valid(o_result_valid), .i_digit(o_digit), .i_conf(o_conf),
        .i_cnn_cycles(cycles), .i_cnn_count(count_q), .i_fc_acc(fc_acc),
        .o_roi_addr(axi_roi_addr), .i_roi_data(i_roi_data),
        .o_inj_we(inj_we), .o_inj_addr(inj_waddr), .o_inj_data(inj_wdata));

    // The video overlay hides a result whose confidence is below CONF_MIN (default 0: show all).
    // Only the picture on the TV is filtered; the RESULT register for the ARM is unchanged.
    assign o_overlay_valid = o_result_valid && (o_conf >= conf_min);

    // ---- start logic -----------------------------------------------------------------
    logic       start, cnn_done, src_inject_q, bank_q;
    logic [9:0] cnn_addr;
    logic [7:0] inj_rdata, cnn_in;
    logic [3:0] cnn_digit;
    logic [7:0] cnn_conf;

    assign start = !busy_q && ((i_frame_pulse && cnn_enable && !inject_mode) || cnn_start_req);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy_q         <= 1'b0;
            o_result_valid <= 1'b0;
            o_digit        <= '0;
            o_conf         <= '0;
            count_q        <= '0;
        end else begin
            if (start) begin
                busy_q       <= 1'b1;
                src_inject_q <= inject_mode;
                bank_q       <= i_ready_bank;
            end else if (cnn_done) begin
                busy_q         <= 1'b0;
                o_digit        <= cnn_digit;
                o_conf         <= cnn_conf;
                o_result_valid <= 1'b1;
                count_q        <= count_q + 1'b1;
            end
        end
    end

    // ---- input memories -------------------------------------------------------------
    // ROI buffer port B: the CNN owns it while busy, otherwise AXI readback
    assign o_roi_addr = busy_q ? {bank_q, cnn_addr} : axi_roi_addr;

    ram_tdp #(.DW(8), .AW(10)) u_inject_ram (
        .clk_a(clk), .we_a(inj_we), .addr_a(inj_waddr), .din_a(inj_wdata), .dout_a(),
        .clk_b(clk), .we_b(1'b0), .addr_b(cnn_addr), .din_b(8'd0), .dout_b(inj_rdata));

    assign cnn_in = src_inject_q ? inj_rdata : i_roi_data;

    // ---- the CNN accelerator ------------------------------------------------------------
    cnn_top #(.P(P), .WROM_FILE(WROM_FILE), .BROM_FILE(BROM_FILE)) u_cnn (
        .clk(clk), .rst_n(rst_n), .i_start(start), .o_busy(), .o_done(cnn_done),
        .o_in_addr(cnn_addr), .i_in_data(cnn_in),
        .o_digit(cnn_digit), .o_conf(cnn_conf), .o_fc_acc(fc_acc), .o_cycles(cycles));

endmodule

`default_nettype wire
