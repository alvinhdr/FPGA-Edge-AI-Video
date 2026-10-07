// =============================================================================
// File   : axil_regs.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Hand-written AXI4-Lite slave: control/status registers for the ARM,
//          read access to the 28x28 ROI buffer, write access to the CNN test-image
//          (inject) RAM. Clock: clk_acc (100 MHz).
//
// Register map (byte offsets from the base address, 32-bit registers):
//   0x0000 ID         RO  0xED6E_0006  (project tag + phase)
//   0x0004 CTRL       RW  [0] invert (reset 1)   [1] thresh_en (0)   [2] freeze (0)
//                         [3] cnn_enable (1): run the CNN on every new ROI frame
//                         [4] inject_mode (0): CNN reads the inject RAM instead of the ROI
//   0x0008 THRESH     RW  [7:0] threshold T (reset 64)
//   0x000C ROI_POS    RW  [10:0] ROI x0 (reset 528)  [26:16] ROI y0 (reset 248)
//   0x0010 STATUS     RO  [0] ready bank
//   0x0014 FRAME_CNT  RO  number of complete ROI captures since reset
//   0x0018 CNN_START  WO  write with bit 0 = 1: run the CNN once (on the inject RAM in inject mode)
//   0x001C RESULT     RO  [3:0] digit  [15:8] confidence  [16] valid (a result exists)  [31] CNN busy
//   0x0020 CNN_CYCLES RO  clocks of the last inference (hardware cycle counter)
//   0x0024 CNN_COUNT  RO  number of finished inferences since reset
//   0x0040 + 4*k      RO  FC accumulator k (k = 0..9, signed), for debugging
//   0x1000 + 4*i      RO  ROI pixel i (i = 0..783) of the READY bank, in [7:0]
//   0x2000 + 4*i      WO  inject RAM pixel i (i = 0..783), [7:0]
//
// AXI4-Lite rules followed: a write is accepted when address AND data are both
// valid; one response per transfer; reads have 1 extra clock for the RAM.
// =============================================================================
`default_nettype none

module axil_regs #(
    parameter logic [31:0] ID_VALUE = 32'hED6E_0006
) (
    input  wire         clk,
    input  wire         rst_n,              // synchronous, active low

    // AXI4-Lite slave
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

    // Settings (clk domain; ROI settings are crossed to clk_pix by cdc_bus_sync in top)
    output logic        o_invert,
    output logic        o_thresh_en,
    output logic        o_freeze,
    output logic        o_cnn_enable,
    output logic        o_inject_mode,
    output logic [7:0]  o_thresh,
    output logic [10:0] o_roi_x0,
    output logic [10:0] o_roi_y0,
    output logic        o_cnn_start,        // 1-clock pulse

    // Status (clk domain)
    input  wire         i_frame_pulse,      // 1 clock per completed ROI capture
    input  wire         i_ready_bank,
    input  wire         i_cnn_busy,
    input  wire         i_result_valid,
    input  wire  [3:0]  i_digit,
    input  wire  [7:0]  i_conf,
    input  wire  [31:0] i_cnn_cycles,
    input  wire  [31:0] i_cnn_count,
    input  wire signed [31:0] i_fc_acc [10],

    // ROI buffer read port (port B of the dual-clock RAM, 1-clock latency)
    output logic [10:0] o_roi_addr,         // {bank, index}
    input  wire  [7:0]  i_roi_data,

    // Inject RAM write port
    output logic        o_inj_we,
    output logic [9:0]  o_inj_addr,
    output logic [7:0]  o_inj_data
);

    localparam logic [15:0] A_ID = 16'h0000, A_CTRL = 16'h0004, A_THRESH = 16'h0008,
                            A_ROI = 16'h000C, A_STATUS = 16'h0010, A_FCNT = 16'h0014,
                            A_START = 16'h0018, A_RESULT = 16'h001C, A_CYC = 16'h0020,
                            A_CNT = 16'h0024;
    localparam int          ROI_PIXELS = 784;

    // ---- registers ------------------------------------------------------------
    logic [31:0] ctrl_q, thresh_q, roi_q, fcnt_q;

    assign o_invert      = ctrl_q[0];
    assign o_thresh_en   = ctrl_q[1];
    assign o_freeze      = ctrl_q[2];
    assign o_cnn_enable  = ctrl_q[3];
    assign o_inject_mode = ctrl_q[4];
    assign o_thresh      = thresh_q[7:0];
    assign o_roi_x0      = roi_q[10:0];
    assign o_roi_y0      = roi_q[26:16];

    function automatic logic [31:0] apply_strb(input logic [31:0] old, input logic [31:0] data,
                                               input logic [3:0] strb);
        for (int i = 0; i < 4; i++) if (strb[i]) old[8*i +: 8] = data[8*i +: 8];
        return old;
    endfunction

    // ---- write channel ----------------------------------------------------------
    logic aw_hs;
    assign aw_hs         = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = aw_hs;
    assign s_axi_wready  = aw_hs;
    assign s_axi_bresp   = 2'b00;          // OKAY

    always_ff @(posedge clk) begin
        o_cnn_start <= 1'b0;
        o_inj_we    <= 1'b0;
        if (!rst_n) begin
            ctrl_q       <= 32'h0000_0009;                 // invert on, cnn_enable on
            thresh_q     <= 32'd64;
            roi_q        <= {5'd0, 11'd248, 5'd0, 11'd528};
            s_axi_bvalid <= 1'b0;
        end else begin
            if (aw_hs) begin
                if (s_axi_awaddr[15:12] == 4'h2) begin       // inject RAM window
                    o_inj_we   <= (s_axi_awaddr[11:2] < ROI_PIXELS) && s_axi_wstrb[0];
                    o_inj_addr <= s_axi_awaddr[11:2];
                    o_inj_data <= s_axi_wdata[7:0];
                end else begin
                    unique case ({s_axi_awaddr[15:2], 2'b00})
                        A_CTRL:   ctrl_q   <= apply_strb(ctrl_q,   s_axi_wdata, s_axi_wstrb) & 32'h1F;
                        A_THRESH: thresh_q <= apply_strb(thresh_q, s_axi_wdata, s_axi_wstrb) & 32'hFF;
                        A_ROI:    roi_q    <= apply_strb(roi_q,    s_axi_wdata, s_axi_wstrb) & 32'h07FF_07FF;
                        A_START:  o_cnn_start <= s_axi_wstrb[0] && s_axi_wdata[0];
                        default: ;                             // read-only or unused: ignored
                    endcase
                end
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---- frame counter ------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n)             fcnt_q <= '0;
        else if (i_frame_pulse) fcnt_q <= fcnt_q + 1'b1;
    end

    // ---- read channel -------------------------------------------------------------
    // Accept the address, wait one clock for the ROI RAM, then return the data.
    logic        rd_wait_q;
    logic [15:0] rd_addr_q;
    logic [9:0]  roi_idx;

    assign s_axi_arready = !s_axi_rvalid && !rd_wait_q;
    assign s_axi_rresp   = 2'b00;
    assign roi_idx       = s_axi_araddr[11:2];
    assign o_roi_addr    = {i_ready_bank, roi_idx};       // RAM reads it on the handshake clock

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_wait_q    <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= '0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                rd_addr_q <= s_axi_araddr;
                rd_wait_q <= 1'b1;
            end
            if (rd_wait_q) begin
                rd_wait_q    <= 1'b0;
                s_axi_rvalid <= 1'b1;
                if (rd_addr_q[15:12] == 4'h1) begin
                    s_axi_rdata <= (rd_addr_q[11:2] < ROI_PIXELS) ? {24'd0, i_roi_data} : 32'd0;
                end else if (rd_addr_q[15:6] == 10'h001 && rd_addr_q[5:2] < 4'd10) begin   // 0x0040..0x0064
                    s_axi_rdata <= i_fc_acc[rd_addr_q[5:2]];
                end else begin
                    unique case ({rd_addr_q[15:2], 2'b00})
                        A_ID:     s_axi_rdata <= ID_VALUE;
                        A_CTRL:   s_axi_rdata <= ctrl_q;
                        A_THRESH: s_axi_rdata <= thresh_q;
                        A_ROI:    s_axi_rdata <= roi_q;
                        A_STATUS: s_axi_rdata <= {31'd0, i_ready_bank};
                        A_FCNT:   s_axi_rdata <= fcnt_q;
                        A_START:  s_axi_rdata <= 32'd0;
                        A_RESULT: s_axi_rdata <= {i_cnn_busy, 14'd0, i_result_valid, i_conf, 4'd0, i_digit};
                        A_CYC:    s_axi_rdata <= i_cnn_cycles;
                        A_CNT:    s_axi_rdata <= i_cnn_count;
                        default:  s_axi_rdata <= 32'hDEAD_BEEF;
                    endcase
                end
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
