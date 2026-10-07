# =============================================================================
# File   : build_hw.tcl
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Build the whole Vivado project from source, in batch mode.
#          Nothing hand-clicked is committed: this script IS the project.
#
# Usage (from the repo root):
#   vivado -mode batch -nojournal -log build/vivado_build.log \
#          -source scripts/build_hw.tcl -tclargs [stage] [P]
#
#   stage = project   : create project + IPs + block design only (fast check)
#           all       : project + synthesis + implementation + bitstream + XSA (default)
#   P     = number of CNN MACs (1, 2, 4, 8, 16), default 8 (the demo). Builds with P != 8
#           go to build/p<P>/ (own project, bitstream, reports) for the Phase 7
#           speed-vs-area table, so the demo build in build/ is never overwritten.
#
# Outputs (all in build/, which is git-ignored):
#   build/vivado/                Vivado project
#   build/edge_ai_video.bit      bitstream
#   build/edge_ai_video.xsa      hardware description for Vitis
#   build/reports/               timing, utilization, power, DRC reports
# =============================================================================

set stage [expr {[llength $argv] > 0 ? [lindex $argv 0] : "all"}]
set cnn_p [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]
if {$cnn_p ni {1 2 4 8 16}} { error "P must be 1, 2, 4, 8 or 16 (got $cnn_p)" }

# ---------------------------------------------------------------------------
# Paths and settings
# ---------------------------------------------------------------------------
set root_dir   [file normalize [file join [file dirname [info script]] ..]]
set build_dir  [expr {$cnn_p == 8 ? [file join $root_dir build] : [file join $root_dir build p$cnn_p]}]
set proj_dir   [file join $build_dir vivado]
set rpt_dir    [file join $build_dir reports]
set proj_name  edge_ai_video
set part       xc7z010clg400-1
set jobs       8

file mkdir $build_dir $rpt_dir

# ---------------------------------------------------------------------------
# 1. Project
# ---------------------------------------------------------------------------
# Start clean: delete the old project so no stale IP folders are left behind.
file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part -force

# Use the newest installed Zybo Z7-10 board file (gives the PS preset: DDR, MIO, UART).
set board_parts [lsort [get_board_parts -quiet digilentinc.com:zybo-z7-10:*]]
if {[llength $board_parts] == 0} {
    error "Zybo Z7-10 board files not found. Install Digilent board files."
}
set board_part [lindex $board_parts end]
puts "INFO: using board part $board_part"
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

# Digilent IP repository (git submodule, pinned commit)
set vl_dir [file join $root_dir third_party vivado-library]
set_property ip_repo_paths [list \
    [file join $vl_dir ip dvi2rgb] \
    [file join $vl_dir ip rgb2dvi] \
    [file join $vl_dir if tmds_v1_0] ] [current_project]
update_ip_catalog -rebuild

# ---------------------------------------------------------------------------
# 2. IP cores
# ---------------------------------------------------------------------------
set ip_dir [file join $proj_dir ip]
file mkdir $ip_dir

# 2a. 125 MHz -> 200 MHz reference clock for dvi2rgb (IDELAYCTRL + EDID logic),
#     plus a 125 MHz copy (clk_sys) for our own logic. sysclk must drive ONLY the PLL:
#     if it also drives fabric logic, Vivado adds a BUFG in front of the PLL, which is
#     illegal in the PLL's default ZHOLD mode (DRC REQP-1712). See docs/TIMING.md.
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_ref -dir $ip_dir
set_property -dict [list \
    CONFIG.PRIMITIVE                  {PLL} \
    CONFIG.PRIM_IN_FREQ               {125.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.CLKOUT2_USED               {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {125.000} \
    CONFIG.USE_RESET                  {false} \
    CONFIG.USE_LOCKED                 {true} ] [get_ips clk_wiz_ref]

# 2b. HDMI input. kClkRange=2 -> for pixel clocks >= 60 MHz (720p = 74.25 MHz).
#     Same value as Digilent's Zybo-Z7-10 HDMI 2025.1 demo.
create_ip -vlnv digilentinc.com:ip:dvi2rgb:2.0 -module_name dvi2rgb_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.kClkRange      {2} \
    CONFIG.kRstActiveHigh {false} \
    CONFIG.kEmulateDDC    {true} \
    CONFIG.kEdidFileName  {dgl_720p_cea.data} \
    CONFIG.kAddBUFG       {true} \
    CONFIG.kDebug         {false} ] [get_ips dvi2rgb_0]


# 2c. HDMI output. Generates its own 5x serial clock with an MMCM.
#     MMCM VCO = 74.25 MHz * 10 = 742.5 MHz (inside the -1 MMCM range 600-1200 MHz).
create_ip -vlnv digilentinc.com:ip:rgb2dvi:1.4 -module_name rgb2dvi_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive      {MMCM} \
    CONFIG.kClkRange          {2} \
    CONFIG.kRstActiveHigh     {false} ] [get_ips rgb2dvi_0]

generate_target {instantiation_template synthesis} [get_ips]

# 2b-1. EDID that offers ONLY 1280x720@60 (made by scripts/make_edid.py).
#       Digilent's dgl_720p_cea.data also lists 1080p, and Windows picks it (148.5 MHz is
#       outside the -1 speed grade). generate_target copies the IP into build/; we overwrite the
#       copy of the 720p file there, so the submodule stays untouched (docs/TIMING.md #5).
set edid_dst [file join $ip_dir dvi2rgb_0 src dgl_720p_cea.data]
if {![file exists $edid_dst]} { error "EDID file not found in generated IP: $edid_dst" }
file copy -force [file join $root_dir rtl edid_720p_only.data] $edid_dst

# dvi2rgb ships XDC files for its debug ILA cores. We build it with kDebug=false,
# so those cores do not exist and the XDCs only give CRITICAL WARNINGs. Disable them.
foreach f [get_files -quiet -of_objects [get_files [get_property IP_FILE [get_ips dvi2rgb_0]]] -filter {FILE_TYPE == XDC}] {
    if {[string match -nocase "*ila*" $f]} {
        set_property IS_ENABLED false $f
        puts "INFO: disabled unused debug constraint file $f"
    }
}

# Print the real port list of every IP (to check top.sv against it)
foreach ip [get_ips] {
    set veo "[file rootname [get_property IP_FILE $ip]].veo"
    puts "INFO: ===== instantiation template for $ip"
    if {[file exists $veo]} {
        set fh [open $veo r]; set txt [read $fh]; close $fh
        foreach line [split $txt "\n"] { if {[regexp {^\s*\.} $line]} { puts "INFO:   $line" } }
    }
}

# ---------------------------------------------------------------------------
# 3. Block design: Zynq PS (ARM, DDR, UART) + the AXI path to our RTL.
#    PS M_AXI_GP0 (AXI3) -> SmartConnect (converts to AXI4-Lite) -> external port
#    M_AXI_LITE, which rtl/top.sv connects to rtl/axil_regs.sv.
#    FCLK_CLK0 = 100 MHz = clk_acc; its reset comes from a proc_sys_reset.
#    Address of our registers: AXIL_BASE (also in sw/common/edge_ai_regs.h).
# ---------------------------------------------------------------------------
set AXIL_BASE 0x43C00000
create_bd_design ps_bd
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0          {1} \
    CONFIG.PCW_EN_CLK0_PORT           {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_EN_RST0_PORT           {1} ] $ps
puts "INFO: PS UART1 enable = [get_property CONFIG.PCW_UART1_PERIPHERAL_ENABLE $ps], IO = [get_property CONFIG.PCW_UART1_UART1_IO $ps]"

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_acc]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc

set m_axi [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_LITE]
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} \
                         CONFIG.FREQ_HZ {100000000}] $m_axi
set clk_port [create_bd_port -dir O -type clk clk_acc]
set_property -dict [list CONFIG.FREQ_HZ {100000000} CONFIG.ASSOCIATED_BUSIF {M_AXI_LITE}] $clk_port
set rst_port [create_bd_port -dir O -type rst rst_acc_n]

connect_bd_net [get_bd_pins $ps/FCLK_CLK0] [get_bd_pins $ps/M_AXI_GP0_ACLK] \
    [get_bd_pins $sc/aclk] [get_bd_pins $rst/slowest_sync_clk] $clk_port
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $sc/aresetn] $rst_port
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_GP0] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] $m_axi

assign_bd_address -offset $AXIL_BASE -range 64K \
    -target_address_space [get_bd_addr_spaces $ps/Data] [get_bd_addr_segs M_AXI_LITE/Reg]
puts "INFO: AXI-Lite registers at [format 0x%08X $AXIL_BASE] (64 KB)"
validate_bd_design
save_bd_design
set bd_file [get_files ps_bd.bd]
generate_target all $bd_file
# make_wrapper returns a plain string; wrap it in [list] so a path with spaces stays one item.
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse [list $wrapper]

# ---------------------------------------------------------------------------
# 4. Our sources and constraints
# ---------------------------------------------------------------------------
add_files -norecurse [glob [file join $root_dir rtl *.sv]]
# ROM contents (font) read with $readmemb by rtl/font_rom.sv
add_files -norecurse [glob [file join $root_dir rtl *.mem]]
# CNN: generated requant constants package + weight/bias ROMs for this P (from ml/export.py)
add_files -norecurse [list [file join $root_dir ml export cnn_params_pkg.sv] \
                           [file join $root_dir ml export wrom_p$cnn_p.mem] \
                           [file join $root_dir ml export brom_p$cnn_p.mem]]
add_files -fileset constrs_1 -norecurse [glob [file join $root_dir constraints *.xdc]]
# Read our XDC LAST: it refers to clocks that IP constraints create (clk_wiz input clock,
# the PS clock clk_fpga_0). Read too early, those clocks do not exist yet (docs/TIMING.md #3).
set_property PROCESSING_ORDER LATE [get_files -of_objects [get_filesets constrs_1] *.xdc]
# Clock groups refer to the PS clock, which only exists in implementation (see that file's header)
set_property USED_IN_SYNTHESIS false [get_files -of_objects [get_filesets constrs_1] *_impl.xdc]
set_property top top [current_fileset]
set_property generic "CNN_P=$cnn_p" [current_fileset]
puts "INFO: CNN_P = $cnn_p, outputs in $build_dir"
update_compile_order -fileset sources_1

if {$stage eq "project"} {
    # Print the block design wrapper ports (to check rtl/top.sv against them)
    set fh [open $wrapper r]; set txt [read $fh]; close $fh
    foreach line [split $txt "\n"] { if {[regexp {^\s*(input|output|inout)} $line]} { puts "INFO: wrapper: [string trim $line]" } }
    puts "INFO: stage=project done."
    exit 0
}

# ---------------------------------------------------------------------------
# 5. Synthesis, implementation, bitstream
# ---------------------------------------------------------------------------
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed" }

# ---------------------------------------------------------------------------
# 6. Reports and outputs
# ---------------------------------------------------------------------------
open_run impl_1
report_timing_summary -max_paths 10 -file [file join $rpt_dir timing_summary.rpt]
report_utilization                 -file [file join $rpt_dir utilization.rpt]
report_clock_utilization           -file [file join $rpt_dir clock_utilization.rpt]
report_power                       -file [file join $rpt_dir power.rpt]
report_drc                         -file [file join $rpt_dir drc.rpt]
report_cdc -details                -file [file join $rpt_dir cdc.rpt]

set bit_src [lindex [glob [file join $proj_dir $proj_name.runs impl_1 *.bit]] 0]
file copy -force $bit_src [file join $build_dir $proj_name.bit]
write_hw_platform -fixed -include_bit -force [file join $build_dir $proj_name.xsa]

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "INFO: ===== BUILD DONE. WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} { puts "CRITICAL WARNING: timing NOT met" }
