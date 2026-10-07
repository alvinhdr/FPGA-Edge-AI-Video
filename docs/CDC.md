# CDC — Clock Domain Crossings

Every place where a signal goes from one clock to another, and how it is made safe.

## Clocks in the design

| Clock | Frequency | Source | Used for |
|---|---|---|---|
| `sysclk` | 125 MHz | Board oscillator (Ethernet PHY), pin K17 | Input to `clk_wiz_ref` only |
| `clk_sys` | 125 MHz | `clk_wiz_ref` (PLL) from `sysclk` | LED blink, status synchronizers |
| `clk_ref` | 200 MHz | `clk_wiz_ref` (PLL) from `sysclk` | `dvi2rgb` IDELAYCTRL + EDID emulator |
| `clk_pix` | 74.25 MHz (720p60) | Recovered from the HDMI input by `dvi2rgb` (MMCM) | Whole pixel pipeline, ROI capture, `rgb2dvi` input |
| serial clocks | 371.25 MHz (5x `clk_pix`) | Inside `dvi2rgb` and `rgb2dvi` (MMCM) | TMDS serializer / deserializer only |
| `clk_acc` | 100 MHz | Zynq PS `FCLK_CLK0` (Vivado name `clk_fpga_0`) | AXI-Lite registers, ROI buffer read port, later the CNN |

The three families (board clock, HDMI clock, PS clock) come from **three different sources**, so they are
**asynchronous**: their edges have no fixed relation. This is declared in
`constraints/zybo_z7_10.xdc` with `set_clock_groups -asynchronous`, so Vivado does not try to time
paths between them. That is only safe because **every** crossing below uses a synchronizer.

Note: `clk_acc` only runs after the ARM software has set up the PS (`ps7_init`). The video path does
not depend on it; the settings bus starts with safe default values (`INIT`) until the ARM writes.

## Synchronizer building blocks

| Module | For | How |
|---|---|---|
| `cdc_sync_2ff` | slow 1-bit **levels** (status, switches) | 2 flip-flops with `ASYNC_REG`: the first may go metastable, the second gives it a full clock to settle |
| `cdc_pulse_sync` | **events** | the source **toggles** a level (a level cannot be missed, a 1-clock pulse can); destination: 2-flop sync + edge detect → 1-clock pulse. Events must be > ~3 destination clocks apart |
| `cdc_bus_sync` | **multi-bit values** | request/acknowledge toggle handshake: the source copies the value into `hold_q` and keeps it **constant** while the request crosses; the destination samples `hold_q` only after it sees the request (so it is stable), then acknowledges |
| `ram_tdp` (dual-clock block RAM) | a whole **buffer** | each port has its own clock; the design guarantees the two ports never use the same bank at the same time (see #7) |

Why not 2 flip-flops per bit for a bus: the bits arrive at slightly different times, so the
destination can see a value that never existed (e.g. 127 → 128 seen as 0 or 255 for one clock).
`tb/tb_cdc.sv` shows this: the handshake passes with 0 errors; a naive per-bit version (mutation test)
fails with 127 torn values such as "got 64 after 127".

## Crossings

| # | Signal | From → To | Type | How it is made safe | Where |
|---|---|---|---|---|---|
| 1 | `pix_locked` | `clk_pix` → `clk_sys` | 1-bit level | `cdc_sync_2ff` | `rtl/top.sv` (`u_sync_pix_locked`) |
| 2 | `ref_locked` → `dvi2rgb.aRst_n` | async → `clk_ref`/`clk_pix` | async reset | reset synchronizers inside `dvi2rgb` | Digilent IP |
| 3 | `pix_locked` → `rgb2dvi.aRst_n` | `clk_pix` → `rgb2dvi` clocks | async reset | reset synchronizer inside `rgb2dvi` | Digilent IP |
| 4 | internal lock/reset signals | `clk_ref` ↔ `clk_pix` | 1-bit | `SyncAsync`/`SyncBase` inside `dvi2rgb` | Digilent IP |
| 5 | `sw[0]`, `sw[1]` | switch (no clock) → `clk_pix` | 1-bit level | `cdc_sync_2ff` | `rtl/top.sv` (`u_sync_sw0/1`) |
| 6 | settings: ROI x0/y0, invert, thresh_en, freeze, threshold (33 bits) | `clk_acc` → `clk_pix` | multi-bit | `cdc_bus_sync` (req/ack handshake). The pixel side also latches them only at the start of a frame, so one captured image never mixes two settings | `rtl/top.sv` (`u_cfg_sync`), `rtl/roi_capture.sv` |
| 7 | ROI image, 28x28 bytes | `clk_pix` → `clk_acc` | buffer | dual-clock block RAM with **2 banks**: `roi_capture` writes bank `w` while readers use the other ("ready") bank, which holds the last complete image. Banks flip only after a full frame. `freeze` stops the flipping for slow readers (ARM UART dump) | `rtl/top.sv` (`u_roi_buffer`), `rtl/roi_capture.sv` |
| 8 | frame-done event | `clk_pix` → `clk_acc` | event | `cdc_pulse_sync` (toggle). One event per 16.7 ms, far slower than the limit | `rtl/top.sv` (`u_frame_sync`) |
| 9 | ready-bank number | `clk_pix` → `clk_acc` | 1-bit, quasi-static | `cdc_sync_2ff`. It changes once per frame, together with the event in #8 | `rtl/top.sv` (`u_bank_sync`) |

LED outputs, `hdmi_rx_hpd` and the switch inputs are slow, human-speed signals: they have a false path in the XDC.

### Why the two banks are needed (#7)
Without them, the ARM (or later the CNN) could read the buffer while the pixel side is overwriting it,
and get the top half of one frame and the bottom half of the next ("tearing"). With two banks the
reader always has one complete, unchanging image for a whole frame time (16.7 ms). The CNN needs
about 0.25 ms per image, so it finishes long before the bank flips again.

Remaining small risk, documented on purpose: the AXI read address uses the ready-bank number at the
moment of each single read. Without `freeze`, a long multi-word read could start in one bank and end
in the other. The ARM program therefore sets `freeze`, waits 3 frames, reads, checks the bank number
did not change, and clears `freeze`.

## Planned (later phases)
- CNN result (digit, confidence) `clk_acc` → `clk_pix`: `cdc_bus_sync` (same handshake as #6).
- Test-image injection: the ARM writes port B of the ROI buffer (bank selection rules as in #7).
