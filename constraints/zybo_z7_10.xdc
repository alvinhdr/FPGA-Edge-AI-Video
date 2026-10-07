## =============================================================================
## File   : zybo_z7_10.xdc
## Project: Real-Time Edge AI Video Processor on FPGA
## Board  : Digilent Zybo Z7-10 (XC7Z010-1CLG400C)
## Purpose: Pin and timing constraints for the top level (rtl/top.sv).
##
## Pin numbers are copied from Digilent's official master XDC:
##   https://github.com/Digilent/digilent-xdc/blob/master/Zybo-Z7-Master.xdc (MIT license)
## and checked against the Zybo-Z7-HW 10/HDMI/2025.1-1 demo constraints.
## Only the signal names were changed to match top.sv.
## =============================================================================

## ---------------------------------------------------------------------------
## 125 MHz board clock (from the Ethernet PHY, always running)
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K17   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]; #IO_L12P_T1_MRCC_35 Sch=sysclk
## No -add: this definition REPLACES the one inside the clk_wiz IP, so there is
## only one clock on this pin (see docs/TIMING.md #2).
create_clock -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { sysclk }]

## ---------------------------------------------------------------------------
## LEDs (debug status)
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L23P_T3_35 Sch=led[0]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L23N_T3_35 Sch=led[1]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_0_35 Sch=led[2]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L3N_T0_DQS_AD1N_35 Sch=led[3]

## ---------------------------------------------------------------------------
## Switches (sw[0] = gray view, sw[1] = hide overlay)
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]; #IO_L19N_T3_VREF_35 Sch=sw[0]
set_property -dict { PACKAGE_PIN P15   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]; #IO_L24P_T3_34 Sch=sw[1]

## ---------------------------------------------------------------------------
## HDMI RX (sink / input port)
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_hpd }];   #IO_L22N_T3_34 Sch=hdmi_rx_hpd
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_scl }];   #IO_L22P_T3_34 Sch=hdmi_rx_scl
set_property -dict { PACKAGE_PIN Y19   IOSTANDARD LVCMOS33 } [get_ports { hdmi_rx_sda }];   #IO_L17N_T2_34 Sch=hdmi_rx_sda
set_property -dict { PACKAGE_PIN U19   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_clk_n }]; #IO_L12N_T1_MRCC_34 Sch=hdmi_rx_clk_n
set_property -dict { PACKAGE_PIN U18   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_clk_p }]; #IO_L12P_T1_MRCC_34 Sch=hdmi_rx_clk_p
set_property -dict { PACKAGE_PIN W20   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_n[0] }];  #IO_L16N_T2_34 Sch=hdmi_rx_n[0]
set_property -dict { PACKAGE_PIN V20   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_p[0] }];  #IO_L16P_T2_34 Sch=hdmi_rx_p[0]
set_property -dict { PACKAGE_PIN U20   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_n[1] }];  #IO_L15N_T2_DQS_34 Sch=hdmi_rx_n[1]
set_property -dict { PACKAGE_PIN T20   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_p[1] }];  #IO_L15P_T2_DQS_34 Sch=hdmi_rx_p[1]
set_property -dict { PACKAGE_PIN P20   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_n[2] }];  #IO_L14N_T2_SRCC_34 Sch=hdmi_rx_n[2]
set_property -dict { PACKAGE_PIN N20   IOSTANDARD TMDS_33  } [get_ports { hdmi_rx_p[2] }];  #IO_L14P_T2_SRCC_34 Sch=hdmi_rx_p[2]

## TMDS clock = pixel clock. 720p60 -> 74.25 MHz -> 13.468 ns.
create_clock -name hdmi_rx_clk -period 13.468 -waveform {0.000 6.734} [get_ports { hdmi_rx_clk_p }]

## ---------------------------------------------------------------------------
## HDMI TX (source / output port)
## ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H17   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_n }]; #IO_L13N_T2_MRCC_35 Sch=hdmi_tx_clk_n
set_property -dict { PACKAGE_PIN H16   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_clk_p }]; #IO_L13P_T2_MRCC_35 Sch=hdmi_tx_clk_p
set_property -dict { PACKAGE_PIN D20   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[0] }];  #IO_L4N_T0_35 Sch=hdmi_tx_n[0]
set_property -dict { PACKAGE_PIN D19   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[0] }];  #IO_L4P_T0_35 Sch=hdmi_tx_p[0]
set_property -dict { PACKAGE_PIN B20   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[1] }];  #IO_L1N_T0_AD0N_35 Sch=hdmi_tx_n[1]
set_property -dict { PACKAGE_PIN C20   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[1] }];  #IO_L1P_T0_AD0P_35 Sch=hdmi_tx_p[1]
set_property -dict { PACKAGE_PIN A20   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[2] }];  #IO_L2N_T0_AD8N_35 Sch=hdmi_tx_n[2]
set_property -dict { PACKAGE_PIN B19   IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[2] }];  #IO_L2P_T0_AD8P_35 Sch=hdmi_tx_p[2]

## ---------------------------------------------------------------------------
## Clock domain crossings (see docs/CDC.md)
## The board clock family (sysclk, 200 MHz ref clock) and the HDMI clock family
## (pixel clock, 5x serial clocks) come from different oscillators, so they are
## asynchronous. Every signal that crosses between them goes through a
## synchronizer (inside the Digilent IP, or cdc_sync_2ff in our RTL).
## ---------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_pin] \
    -group [get_clocks -include_generated_clocks hdmi_rx_clk]

## Slow, human-speed I/O: no timing requirement (inputs are synchronized in RTL).
set_false_path -to   [get_ports { led[*] hdmi_rx_hpd }]
set_false_path -from [get_ports { sw[*] }]
## DDC is slow I2C (100 kHz) handled by the EDID emulator inside dvi2rgb.
set_false_path -from [get_ports { hdmi_rx_scl hdmi_rx_sda }]
set_false_path -to   [get_ports { hdmi_rx_scl hdmi_rx_sda }]
