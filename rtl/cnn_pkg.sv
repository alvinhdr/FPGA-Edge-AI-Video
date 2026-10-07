// =============================================================================
// File   : cnn_pkg.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Network dimensions and number formats of the CNN accelerator
//          (docs/QUANTIZATION.md section 1/2). Requantization constants come
//          from the generated package cnn_params_pkg (ml/export/cnn_params_pkg.sv).
// =============================================================================
`default_nettype none

package cnn_pkg;

    // ---- number formats -------------------------------------------------------
    localparam int ACC_W = 32;      // accumulators (values always fit 25 bits, see spec section 6)

    // ---- network --------------------------------------------------------------
    localparam int IN_HW  = 28;     // input 28x28x1
    localparam int C1     = 8;      // L1: conv 3x3, 8 filters  -> 26x26 -> pool -> 13x13
    localparam int P1_HW  = 13;
    localparam int C2     = 16;     // L2: conv 3x3, 16 filters -> 11x11 -> pool -> 5x5
    localparam int P2_HW  = 5;
    localparam int NFC    = 10;     // FC: 400 -> 10
    localparam int FC_IN  = C2 * P2_HW * P2_HW;   // 400
    localparam int K1     = 1 * 9;                // MACs per L1 output (Cin * 3 * 3)
    localparam int K2     = C1 * 9;               // 72

    // Layer select used by the controller and datapath
    typedef enum logic [1:0] {LAYER_L1 = 2'd0, LAYER_L2 = 2'd1, LAYER_FC = 2'd2} layer_t;

    // Number of output-channel groups when P channels are computed in parallel
    function automatic int ngroups(input int cout, input int p);
        return (cout + p - 1) / p;
    endfunction

endpackage

`default_nettype wire
