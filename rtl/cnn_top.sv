// =============================================================================
// File   : cnn_top.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: The CNN accelerator (docs/QUANTIZATION.md): 28x28 uint8 image in,
//          digit + confidence out, bit-exact to ml/golden_int.py.
//
//   cnn_controller --(addresses, flags)--> memories --> MAC array (P lanes)
//        --> max over the 2x2 pooling window (on raw accumulators)
//        --> write-back: requant --> P1 / P2 feature-map RAM   (L1, L2)
//                        or FC accumulator registers --> argmax (FC)
//
//   Memories: input image (external read port, 1-clock latency), P1 RAM
//   (13x13x8 = 1352 bytes), P2 RAM (5x5x16 = 400 bytes), wide weight ROM
//   (P weights per word) and bias ROM (P biases per word) from ml/export.
//   Pooling is fused: max(requant(a), requant(b)) == requant(max(a, b)) because
//   requantization is monotonic, so only the largest accumulator is requantized.
//
//   P (number of parallel MACs) is a parameter: 1, 2, 4, 8 or 16.
// =============================================================================
`default_nettype none

module cnn_top
    import cnn_pkg::*;
    import cnn_params_pkg::*;
#(
    parameter int    P         = 8,
    parameter string WROM_FILE = "wrom_p8.mem",
    parameter string BROM_FILE = "brom_p8.mem"
) (
    input  wire                     clk,
    input  wire                     rst_n,        // synchronous, active low
    input  wire                     i_start,      // 1-clock pulse: start one inference
    output logic                    o_busy,
    output logic                    o_done,       // 1-clock pulse: results valid

    // input image read port (28x28, row-major; e.g. port B of the ROI buffer)
    output logic [9:0]              o_in_addr,
    input  wire  [7:0]              i_in_data,    // data for o_in_addr, one clock later

    output logic [3:0]              o_digit,
    output logic [7:0]              o_conf,
    output logic signed [ACC_W-1:0] o_fc_acc [NFC],
    output logic [31:0]             o_cycles      // clocks from start to done (last inference)
);

    localparam int OG1 = ngroups(C1, P), OG2 = ngroups(C2, P), OGF = ngroups(NFC, P);
    localparam int WDEPTH = OG1 * K1 + OG2 * K2 + OGF * FC_IN;
    localparam int BDEPTH = OG1 + OG2 + OGF;

    // ---- controller -----------------------------------------------------------
    logic        st_valid, st_first, st_last, st_winfirst;
    layer_t      st_layer, wb_layer;
    logic [10:0] st_in_addr, wb_addr;
    logic [12:0] st_w_addr;
    logic [5:0]  st_b_addr;
    logic        wb_valid, wb_en;
    logic [3:0]  wb_p;
    logic        am_start, am_done;

    cnn_controller #(.P(P)) u_ctrl (
        .clk(clk), .rst_n(rst_n), .i_start(i_start), .i_argmax_done(am_done),
        .o_step_valid(st_valid), .o_step_layer(st_layer), .o_step_first(st_first),
        .o_step_last(st_last), .o_win_first(st_winfirst),
        .o_in_addr(st_in_addr), .o_w_addr(st_w_addr), .o_b_addr(st_b_addr),
        .o_wb_valid(wb_valid), .o_wb_layer(wb_layer), .o_wb_p(wb_p), .o_wb_en(wb_en),
        .o_wb_addr(wb_addr), .o_argmax_start(am_start), .o_busy(o_busy), .o_done(o_done));

    // ---- memories (all: registered read, 1-clock latency) ------------------------
    (* rom_style = "block" *) logic [P*8-1:0]     wrom [WDEPTH];
    (* rom_style = "block" *) logic [P*ACC_W-1:0] brom [BDEPTH];
    initial begin
        $readmemh(WROM_FILE, wrom);
        $readmemh(BROM_FILE, brom);
    end

    logic [P*8-1:0]     w_q;
    logic [P*ACC_W-1:0] b_q;
    always_ff @(posedge clk) begin
        w_q <= wrom[st_w_addr];
        b_q <= brom[st_b_addr];
    end

    assign o_in_addr = st_in_addr[9:0];

    logic        rq_valid;
    logic [7:0]  rq_q;
    logic [11:0] rq_tag;               // {0 = P1 RAM / 1 = P2 RAM, address}
    logic [7:0]  p1_rdata, p2_rdata;

    ram_tdp #(.DW(8), .AW(11)) u_p1_ram (
        .clk_a(clk), .we_a(rq_valid && !rq_tag[11]), .addr_a(rq_tag[10:0]), .din_a(rq_q), .dout_a(),
        .clk_b(clk), .we_b(1'b0), .addr_b(st_in_addr), .din_b(8'd0), .dout_b(p1_rdata));

    ram_tdp #(.DW(8), .AW(9)) u_p2_ram (
        .clk_a(clk), .we_a(rq_valid && rq_tag[11]), .addr_a(rq_tag[8:0]), .din_a(rq_q), .dout_a(),
        .clk_b(clk), .we_b(1'b0), .addr_b(st_in_addr[8:0]), .din_b(8'd0), .dout_b(p2_rdata));

    // ---- pipeline timing (cycle T = controller step visible) -----------------------------
    //   T   addresses at the memories
    //   T+1 memory data (f1)           -> activation mux
    //   T+2 registered MAC inputs (f2) -> MAC stage 1 (multiply)
    //   T+3 MAC stage 2 (accumulate)
    //   T+4 accumulator ready (f4)     -> max over the pooling window
    //   T+5 max ready: the controller's write-back may be visible (DRAIN = 4)
    logic   f1_valid = 1'b0, f1_first, f1_last, f1_winfirst;
    layer_t f1_layer;
    logic   f2_valid = 1'b0, f2_first, f2_last, f2_winfirst;
    logic   f3_valid = 1'b0, f3_last, f3_winfirst;
    logic   f4_valid = 1'b0, f4_last, f4_winfirst;

    always_ff @(posedge clk) begin
        f1_valid <= st_valid;  f1_first <= st_first;  f1_last <= st_last;  f1_winfirst <= st_winfirst;
        f1_layer <= st_layer;
        f2_valid <= f1_valid;  f2_first <= f1_first;  f2_last <= f1_last;  f2_winfirst <= f1_winfirst;
        f3_valid <= f2_valid;  f3_last  <= f2_last;   f3_winfirst <= f2_winfirst;
        f4_valid <= f3_valid;  f4_last  <= f3_last;   f4_winfirst <= f3_winfirst;
    end

    // ---- MAC inputs: activation mux, then a register stage ------------------------------
    // (the register takes the slow block-RAM clock-to-out and the mux out of the MAC path)
    logic [7:0]              x, x_r;
    logic [P*8-1:0]          w_r;
    logic [P*ACC_W-1:0]      b_r;
    logic signed [ACC_W-1:0] acc [P];

    always_comb begin
        unique case (f1_layer)
            LAYER_L1: x = i_in_data;
            LAYER_L2: x = p1_rdata;
            default:  x = p2_rdata;
        endcase
    end

    always_ff @(posedge clk) begin
        x_r <= x;
        w_r <= w_q;
        b_r <= b_q;
    end

    cnn_mac_array #(.P(P)) u_mac (
        .clk(clk), .i_valid(f2_valid), .i_first(f2_first),
        .i_x(x_r), .i_w(w_r), .i_bias(b_r), .o_acc(acc));

    // ---- max over the pooling window (raw accumulators) ---------------------------------
    logic signed [ACC_W-1:0] max_q [P];

    always_ff @(posedge clk) begin
        if (f4_valid && f4_last) begin
            for (int p = 0; p < P; p++) begin
                if (f4_winfirst || acc[p] > max_q[p]) max_q[p] <= acc[p];
            end
        end
    end

    // ---- write-back: requant to feature-map RAM (L1, L2) or FC registers ---------------
    logic signed [ACC_W-1:0] wb_val;
    assign wb_val = max_q[wb_p];

    cnn_requant #(.TAG_W(12)) u_rq (
        .clk     (clk),
        .i_valid (wb_valid && wb_en && (wb_layer != LAYER_FC)),
        .i_acc   (wb_val),
        .i_m     ((wb_layer == LAYER_L1) ? 16'(QP_M1) : 16'(QP_M2)),
        .i_s     ((wb_layer == LAYER_L1) ? 6'(QP_S1)  : 6'(QP_S2)),
        .i_tag   ({wb_layer == LAYER_L2, wb_addr}),
        .o_valid (rq_valid),
        .o_q     (rq_q),
        .o_tag   (rq_tag)
    );

    always_ff @(posedge clk) begin
        if (wb_valid && wb_en && wb_layer == LAYER_FC) o_fc_acc[wb_addr[3:0]] <= wb_val;
    end

    // ---- argmax + confidence ------------------------------------------------------------
    cnn_argmax #(.MC(QP_MC), .SC(QP_SC)) u_argmax (
        .clk(clk), .rst_n(rst_n), .i_start(am_start), .i_acc(o_fc_acc),
        .o_done(am_done), .o_digit(o_digit), .o_conf(o_conf));

    // ---- cycle counter ----------------------------------------------------------------
    logic [31:0] cyc_q;
    always_ff @(posedge clk) begin
        if (!rst_n)       begin cyc_q <= '0; o_cycles <= '0; end
        else if (i_start) cyc_q <= 32'd1;
        else if (o_busy)  cyc_q <= cyc_q + 1'b1;
        if (rst_n && o_done) o_cycles <= cyc_q;
    end

endmodule

`default_nettype wire
