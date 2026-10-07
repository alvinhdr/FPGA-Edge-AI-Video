// =============================================================================
// File   : cnn_controller.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: The loop nest of the accelerator as an FSM. It produces one "MAC step"
//          per clock (addresses + flags) and, after each pooled output, P
//          "write-back" commands. All outputs are registered; the datapath in
//          cnn_top follows with fixed latencies.
//
// Loop nest (one layer):
//   for og  in output-channel groups (P channels each)
//     for py, px in pooled output positions
//       for win in the 2x2 pooling window  (dy = win[1], dx = win[0]; FC: 1 window)
//         for k = (i, ky, kx) in the kernel  (FC: k = input index 0..399)
//           MAC step: acc[p] += in[i][2py+dy+ky][2px+dx+kx] * w[og*P+p][k]
//       (wait for the pipeline) then for p in 0..P-1: write back max over the window
//
// Pipeline timing seen from these registered outputs (cycle T = step visible):
//   T addresses, T+1 memory data, T+2 MAC inputs registered, T+3 multiply->accumulate,
//   T+4 acc ready / max updated, T+5 max ready -> first write-back may be visible. So after the last step of a
//   position the FSM waits DRAIN = 4 cycles before the first write-back command.
// =============================================================================
`default_nettype none

module cnn_controller
    import cnn_pkg::*;
#(
    parameter int P = 8
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          i_start,
    input  wire          i_argmax_done,

    // MAC step
    output logic         o_step_valid,
    output layer_t       o_step_layer,
    output logic         o_step_first,      // first MAC of a window sum (load bias)
    output logic         o_step_last,       // last MAC of a window sum
    output logic         o_win_first,       // this window is the first of the pooling window
    output logic [10:0]  o_in_addr,
    output logic [12:0]  o_w_addr,          // up to 5224 words (P = 1)
    output logic [5:0]   o_b_addr,          // up to 34 words (P = 1)

    // write-back of one finished output (max over the pooling window)
    output logic         o_wb_valid,
    output layer_t       o_wb_layer,
    output logic [3:0]   o_wb_p,            // which MAC lane
    output logic         o_wb_en,           // the channel exists (og*P + p < Cout)
    output logic [10:0]  o_wb_addr,         // L1/L2: feature-map address; FC: output index

    output logic         o_argmax_start,
    output logic         o_busy,
    output logic         o_done
);

    // ---- layer constants ------------------------------------------------------
    localparam int OG1 = ngroups(C1, P), OG2 = ngroups(C2, P), OGF = ngroups(NFC, P);
    localparam int DRAIN = 4;                 // pipeline latency, see cnn_top.sv "pipeline timing"
    localparam int LAYER_GAP = 6;             // requant (3) + RAM write (1) + margin

    function automatic int k_of(layer_t l);   return (l == LAYER_L1) ? K1 : (l == LAYER_L2) ? K2 : FC_IN; endfunction
    function automatic int og_of(layer_t l);  return (l == LAYER_L1) ? OG1 : (l == LAYER_L2) ? OG2 : OGF; endfunction
    function automatic int ph_of(layer_t l);  return (l == LAYER_L1) ? P1_HW : (l == LAYER_L2) ? P2_HW : 1; endfunction
    function automatic int cout_of(layer_t l);return (l == LAYER_L1) ? C1 : (l == LAYER_L2) ? C2 : NFC; endfunction
    function automatic int bbase(layer_t l);  return (l == LAYER_L1) ? 0 : (l == LAYER_L2) ? OG1 : OG1 + OG2; endfunction

    // ---- state and loop counters -----------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_RUN, S_DRAIN, S_WB, S_GAP, S_ARGMAX, S_WAIT_ARGMAX} state_t;
    state_t     state;
    layer_t     layer;
    logic [3:0] og, py, px, ci, wbp;
    logic [1:0] win, ky, kx;
    logic [8:0] k;
    logic [2:0] cnt;

    wire        last_kx  = (layer == LAYER_FC) ? 1'b1 : (kx == 2);
    wire        last_ky  = (layer == LAYER_FC) ? 1'b1 : (ky == 2);
    wire        last_k   = (k == k_of(layer) - 1);
    wire        last_win = (layer == LAYER_FC) ? 1'b1 : (win == 2'd3);
    wire        last_px  = (px == ph_of(layer) - 1);
    wire        last_py  = (py == ph_of(layer) - 1);
    wire        last_og  = (og == og_of(layer) - 1);

    // Addresses of the current step (combinational from the counters)
    logic [4:0]  row, col;
    logic [10:0] in_addr_c;
    logic [3:0]  wb_o;

    // One formula per layer with CONSTANT sizes: a multiply by a constant is just a few
    // shifts and adds. A layer-dependent size made Vivado build real multipliers in this
    // path, which failed timing at 100 MHz (docs/TIMING.md #4).
    logic [12:0] w_addr_c;
    always_comb begin
        row = 5'(2 * py + win[1] + ky);
        col = 5'(2 * px + win[0] + kx);
        unique case (layer)
            LAYER_L1: begin
                in_addr_c = 11'(row * IN_HW + col);                                   // ci = 0
                w_addr_c  = 13'(og * K1 + k);
            end
            LAYER_L2: begin
                in_addr_c = 11'(ci * (P1_HW * P1_HW) + row * P1_HW + col);
                w_addr_c  = 13'(OG1 * K1 + og * K2 + k);
            end
            default: begin
                in_addr_c = 11'(k);
                w_addr_c  = 13'(OG1 * K1 + OG2 * K2 + og * FC_IN + k);
            end
        endcase
        wb_o = 4'(og * P + wbp);
    end

    always_ff @(posedge clk) begin
        o_step_valid   <= 1'b0;
        o_wb_valid     <= 1'b0;
        o_argmax_start <= 1'b0;
        o_done         <= 1'b0;

        if (!rst_n) begin
            state  <= S_IDLE;
            o_busy <= 1'b0;
        end else begin
            unique case (state)
                S_IDLE: if (i_start) begin
                    layer <= LAYER_L1;
                    {og, py, px, win, ci, ky, kx, k} <= '0;
                    o_busy <= 1'b1;
                    state  <= S_RUN;
                end

                S_RUN: begin
                    // issue the step for the current counters
                    o_step_valid <= 1'b1;
                    o_step_layer <= layer;
                    o_step_first <= (k == 0);
                    o_step_last  <= last_k;
                    o_win_first  <= (win == 0);
                    o_in_addr    <= in_addr_c;
                    o_w_addr     <= w_addr_c;
                    o_b_addr     <= 6'(bbase(layer) + og);
                    // advance the kernel counters
                    if (last_k) begin
                        {ci, ky, kx, k} <= '0;
                        if (last_win) begin
                            win   <= '0;
                            cnt   <= 3'(DRAIN - 1);
                            state <= S_DRAIN;
                        end else begin
                            win <= win + 1'b1;
                        end
                    end else begin
                        k <= k + 1'b1;
                        if (last_kx) begin
                            kx <= '0;
                            if (last_ky) begin ky <= '0; ci <= ci + 1'b1; end
                            else           ky <= ky + 1'b1;
                        end else begin
                            kx <= kx + 1'b1;
                        end
                    end
                end

                S_DRAIN: begin
                    if (cnt == 0) begin wbp <= '0; state <= S_WB; end
                    else          cnt <= cnt - 1'b1;
                end

                S_WB: begin
                    o_wb_valid <= 1'b1;
                    o_wb_layer <= layer;
                    o_wb_p     <= wbp;
                    o_wb_en    <= (wb_o < cout_of(layer));
                    if      (layer == LAYER_L1) o_wb_addr <= 11'(wb_o * P1_HW * P1_HW + py * P1_HW + px);
                    else if (layer == LAYER_L2) o_wb_addr <= 11'(wb_o * P2_HW * P2_HW + py * P2_HW + px);
                    else                        o_wb_addr <= 11'(wb_o);
                    if (wbp == P - 1) begin
                        // next pooled position / channel group / layer
                        if (!last_px)       begin px <= px + 1'b1; state <= S_RUN; end
                        else if (!last_py)  begin px <= '0; py <= py + 1'b1; state <= S_RUN; end
                        else if (!last_og)  begin px <= '0; py <= '0; og <= og + 1'b1; state <= S_RUN; end
                        else begin
                            {px, py, og} <= '0;
                            if (layer == LAYER_FC) state <= S_ARGMAX;
                            else begin cnt <= 3'(LAYER_GAP - 1); state <= S_GAP; end
                        end
                    end
                    wbp <= wbp + 1'b1;
                end

                S_GAP: begin       // let the last write-backs reach the feature-map RAM
                    if (cnt == 0) begin
                        layer <= (layer == LAYER_L1) ? LAYER_L2 : LAYER_FC;
                        state <= S_RUN;
                    end else cnt <= cnt - 1'b1;
                end

                S_ARGMAX: begin o_argmax_start <= 1'b1; state <= S_WAIT_ARGMAX; end

                S_WAIT_ARGMAX: if (i_argmax_done) begin
                    o_done <= 1'b1;
                    o_busy <= 1'b0;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
