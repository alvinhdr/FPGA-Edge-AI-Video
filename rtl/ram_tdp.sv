// =============================================================================
// File   : ram_tdp.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: True dual-port RAM, each port with its OWN clock (Vivado infers a
//          block RAM). Read latency 1 clock, "read first" on each port.
//
// A dual-clock block RAM is the standard way to move a whole buffer between
// clock domains: port A writes in one domain, port B reads in the other. The
// RAM itself handles the crossing; the design only has to make sure a port does
// not read a word while the other port is writing that same word
// (we use two banks for that, see roi_capture.sv and docs/CDC.md).
// =============================================================================
`default_nettype none

module ram_tdp #(
    parameter int DW = 8,     // data width
    parameter int AW = 11     // address width (depth = 2^AW)
) (
    input  wire           clk_a,
    input  wire           we_a,
    input  wire  [AW-1:0] addr_a,
    input  wire  [DW-1:0] din_a,
    output logic [DW-1:0] dout_a,

    input  wire           clk_b,
    input  wire           we_b,
    input  wire  [AW-1:0] addr_b,
    input  wire  [DW-1:0] din_b,
    output logic [DW-1:0] dout_b
);

    (* ram_style = "block" *) logic [DW-1:0] mem [2**AW];

    initial begin
        for (int i = 0; i < 2**AW; i++) mem[i] = '0;
        dout_a = '0;
        dout_b = '0;
    end

    // Plain "always" (not always_ff): the memory array is written from two
    // processes, which is the Vivado template for a true dual-port RAM.
    always @(posedge clk_a) begin
        if (we_a) mem[addr_a] <= din_a;
        dout_a <= mem[addr_a];
    end

    always @(posedge clk_b) begin
        if (we_b) mem[addr_b] <= din_b;
        dout_b <= mem[addr_b];
    end

endmodule

`default_nettype wire
