// =============================================================================
// File   : video_pkg.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: Shared types, constants and helper functions for the pixel pipeline.
//
// Pixel bus order (Digilent dvi2rgb / rgb2dvi, checked in their VHDL source):
//   data[23:16] = RED   (TMDS channel 2)
//   data[15:8]  = BLUE  (TMDS channel 0)
//   data[7:0]   = GREEN (TMDS channel 1)
// This "R-B-G" order is NOT the usual R-G-B. Always use pack_rgb()/get_r/g/b()
// so the order is defined in exactly one place.
// =============================================================================
`default_nettype none

package video_pkg;

    // Pixel position width: 11 bits -> 0..2047 (enough for 1280 x 720)
    localparam int POS_W = 11;

    // One pixel on the video bus, plus its timing signals
    typedef struct packed {
        logic [23:0] data;   // Digilent R-B-G order (see above)
        logic        de;     // data enable: 1 = visible pixel
        logic        hs;     // horizontal sync
        logic        vs;     // vertical sync
    } video_t;

    // Named colors, already in the R-B-G bus order: {R, B, G}
    localparam logic [23:0] COLOR_GREEN = 24'h00_00_FF;
    localparam logic [23:0] COLOR_WHITE = 24'hFF_FF_FF;
    localparam logic [23:0] COLOR_BLACK = 24'h00_00_00;

    function automatic logic [7:0] get_r(input logic [23:0] d); return d[23:16]; endfunction
    function automatic logic [7:0] get_b(input logic [23:0] d); return d[15:8];  endfunction
    function automatic logic [7:0] get_g(input logic [23:0] d); return d[7:0];   endfunction

    function automatic logic [23:0] pack_rgb(input logic [7:0] r,
                                             input logic [7:0] g,
                                             input logic [7:0] b);
        return {r, b, g};
    endfunction

endpackage

`default_nettype wire
