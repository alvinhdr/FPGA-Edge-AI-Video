# =============================================================================
# File   : program.tcl
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Program the Zybo Z7 over JTAG (micro-USB) with xsdb.
#
# Usage (from the repo root):
#   C:\Xilinx\2025.1\Vivado\bin\xsdb.bat scripts/program.tcl bit          -> FPGA only (video path)
#   C:\Xilinx\2025.1\Vivado\bin\xsdb.bat scripts/program.tcl all [app]    -> FPGA + ARM init + run app (default app: hello)
#
# Needs: build/edge_ai_video.bit, and for "all": build/hw/ps7_init.tcl and build/sw/<app>.elf
# =============================================================================

set mode [expr {[llength $argv] > 0 ? [lindex $argv 0] : "bit"}]
set app  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "hello"}]

set root_dir [file normalize [file join [file dirname [info script]] ..]]
set bit_file [file join $root_dir build edge_ai_video.bit]
set ps7_init [file join $root_dir build hw ps7_init.tcl]
set elf_file [file join $root_dir build sw $app.elf]

connect
puts "INFO: JTAG targets:"
puts [targets]

if {$mode eq "all"} {
    # Reset the whole chip so the ARM starts from a clean state.
    targets -set -nocase -filter {name =~ "APU*"}
    rst -system
    after 1000
}

# Program the FPGA (PL)
targets -set -nocase -filter {name =~ "xc7z0*"}
fpga -file $bit_file
puts "INFO: FPGA programmed with $bit_file"

if {$mode eq "all"} {
    # Initialize the PS (clocks, DDR, MIO pins incl. UART) like the boot ROM / FSBL would.
    targets -set -nocase -filter {name =~ "APU*"}
    source $ps7_init
    ps7_init
    ps7_post_config

    # Load and start the program on Cortex-A9 core 0
    targets -set -nocase -filter {name =~ "*A9*#0"}
    dow $elf_file
    con
    puts "INFO: running $elf_file on Cortex-A9 #0"
}

disconnect
