// =============================================================================
// File   : cdc_sync_2ff.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: 2-flip-flop synchronizer for single-bit LEVEL signals that cross
//          into the clk_dst clock domain.
//
// Why: a signal from another clock can change at any time, even exactly at
//      our clock edge. The first flip-flop may then go "metastable" (stuck
//      between 0 and 1 for a short time). The second flip-flop gives it one
//      full clock period to settle, so the output is a clean 0 or 1.
//
// Use only for slow level signals (status bits). NOT for buses or short pulses.
// =============================================================================
`default_nettype none

module cdc_sync_2ff #(
    parameter int  STAGES   = 2,     // number of flip-flops (2 is the minimum)
    parameter bit  INIT_VAL = 1'b0   // value after configuration
) (
    input  wire  clk_dst,            // destination clock
    input  wire  d_async,            // input from another clock domain
    output logic q_sync              // synchronized output in clk_dst domain
);

    // ASYNC_REG tells Vivado: keep these flops close together and do not
    // optimize them away. This gives the most time for metastability to settle.
    (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q = {STAGES{INIT_VAL}};

    always_ff @(posedge clk_dst) begin
        sync_q <= {sync_q[STAGES-2:0], d_async};
    end

    assign q_sync = sync_q[STAGES-1];

endmodule

`default_nettype wire
