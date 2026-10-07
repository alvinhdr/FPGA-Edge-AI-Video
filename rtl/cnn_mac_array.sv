// =============================================================================
// File   : cnn_mac_array.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: P parallel multiply-accumulate units (MACs). Every clock with i_valid,
//          one uint8 activation (the same for all units) is multiplied by P int8
//          weights (one per output channel) and added to P int32 accumulators.
//
//   i_first = 1 : acc[p] = bias[p] + x * w[p]   (start of a new sum; the bias is the start value)
//   i_first = 0 : acc[p] = acc[p]  + x * w[p]
//
// Two pipeline stages (latency 2: o_acc is updated 2 clocks after the input):
//   stage 1: prod = x * w          (registered)
//   stage 2: acc  = base + prod
// One stage (multiply + add in one clock) was too slow at 100 MHz (docs/TIMING.md #4);
// multiply-register-add is also the structure of the DSP48 slice.
// The product uint8 x int8 is 17-bit signed: the activation gets a 0 sign bit.
// =============================================================================
`default_nettype none

module cnn_mac_array
    import cnn_pkg::*;
#(
    parameter int P = 8
) (
    input  wire                     clk,
    input  wire                     i_valid,
    input  wire                     i_first,
    input  wire  [7:0]              i_x,              // activation (uint8), shared
    input  wire  [P*8-1:0]          i_w,              // weights, bank p = bits [8p+7:8p] (int8)
    input  wire  [P*ACC_W-1:0]      i_bias,           // bias, bank p = bits [32p+31:32p] (int32)
    output logic signed [ACC_W-1:0] o_acc [P]
);

    logic               v1 = 1'b0, first1;
    logic [P*ACC_W-1:0] bias1;

    always_ff @(posedge clk) begin
        v1     <= i_valid;
        first1 <= i_first;
        bias1  <= i_bias;
    end

    for (genvar p = 0; p < P; p++) begin : g_mac
        logic signed [7:0]       w;
        (* use_dsp = "yes" *) logic signed [16:0] prod_q;
        logic signed [ACC_W-1:0] base;

        assign w    = i_w[8*p +: 8];
        assign base = first1 ? $signed(bias1[ACC_W*p +: ACC_W]) : o_acc[p];

        always_ff @(posedge clk) begin
            if (i_valid) prod_q   <= $signed({1'b0, i_x}) * w;    // stage 1
            if (v1)      o_acc[p] <= base + prod_q;              // stage 2
        end
    end

endmodule

`default_nettype wire
