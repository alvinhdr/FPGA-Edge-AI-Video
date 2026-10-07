// =============================================================================
// File   : cdc_bus_sync.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Move a MULTI-BIT value (e.g. settings registers) safely from clk_src
//          to clk_dst with a request/acknowledge (toggle) handshake.
//
// Why not one 2-flop synchronizer per bit? The bits of a bus do not arrive at
// exactly the same time, so the destination could see a mix of old and new bits
// for one clock (e.g. ROI x = 0x2F0 while changing from 0x210 to 0x3F0).
//
// How it works:
//   1. Source: when i_data differs from the held copy and no transfer is busy,
//      copy i_data into hold_q and toggle req_q.
//   2. hold_q now stays CONSTANT until the transfer is finished.
//   3. Destination: synchronizes req (2 flops). On a change it copies hold_q
//      (stable for many clocks, so no metastability risk) and toggles ack_q.
//   4. Source: synchronizes ack (2 flops). When ack == req, the transfer is done
//      and the next change can be sent. Changes made while busy are not lost:
//      the newest i_data is sent as soon as the current transfer completes.
//
// The hold_q -> o_data path is an intentional clock crossing (covered by the
// asynchronous clock groups in the XDC; see docs/CDC.md).
// =============================================================================
`default_nettype none

module cdc_bus_sync #(
    parameter int             W    = 8,
    parameter logic [W-1:0]   INIT = '0     // value of o_data before the first transfer
) (
    input  wire          clk_src,
    input  wire  [W-1:0] i_data,           // source domain, may change at any time
    input  wire          clk_dst,
    output logic [W-1:0] o_data            // destination domain
);

    // ---- source domain ----------------------------------------------------
    logic [W-1:0]                        hold_q    = INIT;
    logic                                req_q     = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync_q = '0;
    logic                                busy;

    // ---- destination domain -----------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic [1:0] req_sync_q = '0;
    logic                                ack_q      = 1'b0;
    logic [W-1:0]                        data_q     = INIT;

    assign busy = (req_q != ack_sync_q[1]);

    always_ff @(posedge clk_src) begin
        ack_sync_q <= {ack_sync_q[0], ack_q};
        if (!busy && (i_data != hold_q)) begin
            hold_q <= i_data;
            req_q  <= ~req_q;
        end
    end

    always_ff @(posedge clk_dst) begin
        req_sync_q <= {req_sync_q[0], req_q};
        if (req_sync_q[1] != ack_q) begin
            data_q <= hold_q;
            ack_q  <= req_sync_q[1];
        end
    end

    assign o_data = data_q;

endmodule

`default_nettype wire
