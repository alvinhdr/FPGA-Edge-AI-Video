// =============================================================================
// File   : rgb2gray.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Convert one RGB pixel to an 8-bit gray value. Combinational.
//
//   gray = (77*R + 150*G + 29*B) >> 8
//
// The weights are the ITU-R BT.601 luma weights (0.299, 0.587, 0.114) scaled
// by 256 and rounded so they sum to exactly 256. Then white (255,255,255)
// gives exactly 255. Integer only, so the Python reference matches bit-exactly.
// =============================================================================
`default_nettype none

module rgb2gray
    import video_pkg::*;
(
    input  wire  [23:0] i_data,   // Digilent R-B-G order
    output logic [7:0]  o_gray
);

    localparam logic [7:0] W_R = 8'd77;
    localparam logic [7:0] W_G = 8'd150;
    localparam logic [7:0] W_B = 8'd29;

    logic [15:0] sum;   // max 256 * 255 = 65,280 fits in 16 bits

    always_comb begin
        sum    = W_R * get_r(i_data) + W_G * get_g(i_data) + W_B * get_b(i_data);
        o_gray = sum[15:8];
    end

endmodule

`default_nettype wire
