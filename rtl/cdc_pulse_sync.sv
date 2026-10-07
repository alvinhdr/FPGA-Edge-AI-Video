// =============================================================================
// File   : cdc_pulse_sync.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Move an EVENT from one clock domain to another (toggle synchronizer).
//
//   Source side: the event is a TOGGLE of i_src_toggle (0->1 or 1->0), not a
//   pulse. A 1-clock pulse could be missed by a slower destination clock; a level
//   change cannot be missed. The destination synchronizes the level with 2 flops
//   and makes a 1-clock pulse on every change (edge detect with a 3rd flop).
//
//   Rule: events must be further apart than ~3 destination clocks. Our use
//   ("ROI frame done", once per 16.7 ms) is far slower than that.
// =============================================================================
`default_nettype none

module cdc_pulse_sync (
    input  wire  clk_dst,
    input  wire  i_src_toggle,   // toggles once per event, in the source domain
    output logic o_dst_pulse     // 1-clock pulse per event, in clk_dst domain
);

    (* ASYNC_REG = "TRUE" *) logic [1:0] sync_q = '0;   // synchronizer
    logic                                last_q  = 1'b0; // for edge detect
    logic                                pulse_q = 1'b0;

    always_ff @(posedge clk_dst) begin
        sync_q  <= {sync_q[0], i_src_toggle};
        last_q  <= sync_q[1];
        pulse_q <= sync_q[1] ^ last_q;
    end

    assign o_dst_pulse = pulse_q;

endmodule

`default_nettype wire
