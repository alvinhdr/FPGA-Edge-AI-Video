## =============================================================================
## File   : zybo_z7_10_impl.xdc
## Project: Real-Time Edge AI Video Processor on FPGA
## Purpose: Clock domain crossing constraints. USED IN IMPLEMENTATION ONLY
##          (scripts/build_hw.tcl sets USED_IN_SYNTHESIS false), because the PS
##          clock clk_fpga_0 is created inside the block design, which is
##          synthesized out-of-context: during top-level synthesis it does not
##          exist yet. Implementation is where timing is signed off. See docs/TIMING.md #3.
##
## Three clock families from three different sources, so they are asynchronous:
##   1. board clock (sysclk -> clk_sys, 200 MHz ref clock)
##   2. HDMI clock (recovered pixel clock, 5x serial clocks)
##   3. clk_fpga_0 = clk_acc, 100 MHz from the Zynq PS (AXI-Lite, later the CNN)
## Every signal that crosses between them goes through a synchronizer
## (Digilent IP internals, cdc_sync_2ff, cdc_pulse_sync, cdc_bus_sync, or the
## dual-clock ROI block RAM). See docs/CDC.md.
## =============================================================================
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports sysclk]] \
    -group [get_clocks -include_generated_clocks hdmi_rx_clk] \
    -group [get_clocks -include_generated_clocks clk_fpga_0]
