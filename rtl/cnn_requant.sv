// =============================================================================
// File   : cnn_requant.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Requantization, docs/QUANTIZATION.md section 5:
//
//            q = clamp( (acc * M + 2^(S-1)) >>> S , 0, 255 )
//
//          The clamp at 0 is the ReLU. Pipelined, latency 3 clocks, one value
//          per clock. i_tag travels with the data (e.g. the write address).
//   stage 1: prod = acc * M                (48-bit signed; one DSP48 multiply)
//   stage 2: sum  = prod + 2^(S-1)         (rounding: round half up)
//   stage 3: >>> S (arithmetic = floor), clamp to 0..255
// =============================================================================
`default_nettype none

module cnn_requant #(
    parameter int TAG_W = 12
) (
    input  wire                clk,
    input  wire                i_valid,
    input  wire signed [31:0]  i_acc,
    input  wire        [15:0]  i_m,          // multiplier M (16384..32767)
    input  wire        [5:0]   i_s,          // shift S (15..40)
    input  wire  [TAG_W-1:0]   i_tag,
    output logic               o_valid,
    output logic       [7:0]   o_q,
    output logic [TAG_W-1:0]   o_tag
);

    logic               v1 = 1'b0, v2 = 1'b0, v3 = 1'b0;
    logic signed [47:0] prod1, sum2;
    logic        [5:0]  s1, s2;
    logic [TAG_W-1:0]   t1, t2;
    logic signed [47:0] shifted;

    always_ff @(posedge clk) begin
        // stage 1
        v1    <= i_valid;
        prod1 <= i_acc * $signed({1'b0, i_m});
        s1    <= i_s;
        t1    <= i_tag;
        // stage 2
        v2    <= v1;
        sum2  <= prod1 + (48'sd1 <<< (s1 - 6'd1));
        s2    <= s1;
        t2    <= t1;
        // stage 3
        v3      <= v2;
        o_tag   <= t2;
        if      (shifted < 0)    o_q <= 8'd0;
        else if (shifted > 255)  o_q <= 8'd255;
        else                     o_q <= shifted[7:0];
    end

    assign shifted = sum2 >>> s2;
    assign o_valid = v3;

endmodule

`default_nettype wire
