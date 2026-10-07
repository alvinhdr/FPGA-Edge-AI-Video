# =============================================================================
# File   : synth_cnn.tcl
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Out-of-context synthesis + place & route of the CNN accelerator alone
#          (rtl/cnn_top.sv) at 100 MHz on the XC7Z010, for each MAC count P.
#          Gives timing (WNS) and resources (LUT, FF, BRAM, DSP) per P, for the
#          speed-vs-area table in Phase 7.
#
# Usage (repo root):
#   vivado -mode batch -nojournal -log build/synth_cnn.log -source scripts/synth_cnn.tcl -tclargs 8 4 1
# Result lines: "RESULT P=.. WNS=.. LUT=.. FF=.. BRAM=.. DSP=.." and build/reports/cnn_p<P>_*.rpt
# =============================================================================
set root_dir [file normalize [file join [file dirname [info script]] ..]]
set rpt_dir  [file join $root_dir build reports]
file mkdir $rpt_dir
set plist [expr {[llength $argv] > 0 ? $argv : {8}}]

set srcs [list ml/export/cnn_params_pkg.sv rtl/cnn_pkg.sv rtl/ram_tdp.sv rtl/cnn_mac_array.sv \
               rtl/cnn_requant.sv rtl/cnn_argmax.sv rtl/cnn_controller.sv rtl/cnn_top.sv]

foreach P $plist {
    close_project -quiet
    create_project -in_memory -part xc7z010clg400-1
    # [list ...]: keeps paths with spaces as one item
    foreach s $srcs { read_verilog -sv [list [file join $root_dir $s]] }
    # ROM init files: read_mem makes them available to $readmemh during synthesis
    read_mem [list [file join $root_dir ml export wrom_p$P.mem]]
    read_mem [list [file join $root_dir ml export brom_p$P.mem]]

    synth_design -top cnn_top -part xc7z010clg400-1 -mode out_of_context \
        -generic P=$P -generic WROM_FILE=wrom_p$P.mem -generic BROM_FILE=brom_p$P.mem
    create_clock -name clk_acc -period 10.000 [get_ports clk]
    opt_design
    place_design
    route_design

    report_timing_summary -file [file join $rpt_dir cnn_p${P}_timing.rpt]
    report_utilization    -file [file join $rpt_dir cnn_p${P}_util.rpt]
    set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set lut  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
    set ff   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
    set bram [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]] + 0.5 * [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]}]
    set dsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
    puts "RESULT P=$P WNS=$wns LUT=$lut FF=$ff BRAM=$bram DSP=$dsp"
}
