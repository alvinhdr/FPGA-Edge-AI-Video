// =============================================================================
// File   : cnn_argmax.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Prediction and confidence from the 10 FC accumulators
//          (docs/QUANTIZATION.md section 5):
//            digit = index of the largest acc (ties -> smallest index)
//            top2  = largest acc of the other indices
//            conf  = min(255, ((top1 - top2) * MC + 2^(SC-1)) >> SC)
//          Sequential: one accumulator per clock (10 clocks), then 2 clocks for conf.
// =============================================================================
`default_nettype none

module cnn_argmax
    import cnn_pkg::*;
#(
    parameter int MC = 26807,
    parameter int SC = 21
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     i_start,
    input  wire signed [ACC_W-1:0]  i_acc [NFC],
    output logic                    o_done,       // 1-clock pulse, outputs valid from then on
    output logic [3:0]              o_digit,
    output logic [7:0]              o_conf
);

    // The confidence math is split over 3 clocks (S_DIFF, S_MUL, S_RND). Doing
    // subtract + multiply + add in one clock was the critical path at 100 MHz
    // (19 logic levels, WNS -2.0 ns; see docs/TIMING.md #4).
    typedef enum logic [2:0] {S_IDLE, S_SCAN, S_DIFF, S_MUL, S_RND, S_OUT} state_t;
    state_t                  state;
    logic [3:0]              k;
    logic signed [ACC_W-1:0] top1, top2;
    logic [3:0]              idx1;
    logic        [ACC_W-1:0] diff;
    logic        [47:0]      prod, scaled;

    always_ff @(posedge clk) begin
        o_done <= 1'b0;
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            unique case (state)
                S_IDLE: if (i_start) begin
                    top1  <= i_acc[0];
                    idx1  <= 4'd0;
                    top2  <= {1'b1, {(ACC_W-1){1'b0}}};    // most negative value
                    k     <= 4'd1;
                    state <= S_SCAN;
                end
                S_SCAN: begin
                    if (i_acc[k] > top1) begin               // strictly greater: ties keep the smaller index
                        top2 <= top1;
                        top1 <= i_acc[k];
                        idx1 <= k;
                    end else if (i_acc[k] > top2) begin
                        top2 <= i_acc[k];
                    end
                    if (k == NFC - 1) state <= S_DIFF;
                    k <= k + 1'b1;
                end
                S_DIFF: begin
                    diff  <= ACC_W'(top1 - top2);           // >= 0 and < 2^25
                    state <= S_MUL;
                end
                S_MUL: begin
                    prod  <= 48'(diff) * 48'(MC);           // MC < 2^15: fits easily in 48 bits
                    state <= S_RND;
                end
                S_RND: begin
                    scaled <= prod + (48'd1 << (SC - 1));
                    state  <= S_OUT;
                end
                S_OUT: begin
                    o_digit <= idx1;
                    o_conf  <= ((scaled >> SC) > 255) ? 8'd255 : 8'((scaled >> SC));
                    o_done  <= 1'b1;
                    state   <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
