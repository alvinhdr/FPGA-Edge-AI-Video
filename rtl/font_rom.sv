// =============================================================================
// File   : font_rom.sv
// Project: Real-Time Edge AI Video Processor on FPGA
// Purpose: 8x8 font ROM for the digits 0..9. Combinational read (small enough
//          for LUTs: 80 x 8 bits). Contents come from font_digits_8x8.mem.
// =============================================================================
`default_nettype none

module font_rom #(
    parameter string FONT_FILE = "font_digits_8x8.mem"
) (
    input  wire  [3:0] i_digit,   // 0..9 (10..15 give an empty glyph)
    input  wire  [2:0] i_row,     // 0 = top row
    output logic [7:0] o_bits     // bit 7 = leftmost pixel
);

    localparam int NUM_DIGITS = 10;
    localparam int ROWS       = 8;

    logic [7:0] rom [NUM_DIGITS*ROWS];

    initial begin
        $readmemb(FONT_FILE, rom);
    end

    always_comb begin
        if (i_digit < NUM_DIGITS) o_bits = rom[{i_digit, i_row}];
        else                      o_bits = 8'h00;
    end

endmodule

`default_nettype wire
