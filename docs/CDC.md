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
| 10 | CNN result: valid, digit, confidence (13 bits) | `clk_acc` → `clk_pix` | multi-bit | `cdc_bus_sync` (req/ack handshake, same as #6). The `valid` bit that crosses is `o_overlay_valid = result_valid && conf >= CONF_MIN`: the compare is made from `clk_acc` registers, before the synchronizer, so it adds no crossing | `rtl/top.sv` (`u_result_sync`), `rtl/ai_core.sv` |
| 11 | ROI buffer port B (CNN read / AXI readback), test-image (inject) RAM | all in `clk_acc` | same domain | Not a crossing: the read side of #7 and the inject RAM are in `clk_acc`. The CNN owns port B while it runs (see the limits below) | `rtl/ai_core.sv` |

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

## Vivado CDC report review (`build/reports/cdc.rpt`, Phase 4)
- **CDC-3 Info (15):** 1-bit synchronizers with `ASYNC_REG` recognized (ours and Digilent's). Good.
- **CDC-15 Warning (33):** "clock enable controlled CDC structure" on `u_cfg_sync/hold_q -> data_q`.
  This is exactly the req/ack handshake: the destination register only loads (clock enable) after the
  request has been synchronized, when `hold_q` is stable. Expected, reviewed, OK.
- **CDC-7 Critical (3), CDC-11 Critical (2):** all inside Digilent's `dvi2rgb` (`LockLostReset`,
  `LockedSync`, `SyncBaseOvf`): its own asynchronous-reset synchronizers, with false paths in
  Digilent's XDC. Not in our RTL; reviewed and accepted (third-party IP, used unchanged, works on the board).

## Known limits (found in the Phase 8 review, 2026-10-08)

A read-only review of the RTL found no wrong crossing in the datapath, and the handshake and pulse synchronizers were judged
correct. These limits remain on purpose or by lack of time; the ARM demo program keeps clear of them:

1. **ROI position must stay on screen.** The register accepts any 11-bit x0/y0. If x0 > 1056 or y0 > 496, the last 8x8 block never
   completes, so the banks stop flipping, no frame-done event is sent, and the result on the TV freezes. `sw/edge_ai_demo` clamps the
   position; the hardware does not.
2. **ROI readback while the CNN runs.** The CNN owns buffer port B while it is busy; an AXI readback in that time returns wrong
   bytes (no error). The ARM capture code turns `cnn_enable` off first. `FREEZE` protects against bank flips, not against this.
3. **CNN_START while busy is dropped.** The ARM tests and the benchmark wait for the CNN to finish first.
4. **Frame-done event and ready-bank bit use two separate synchronizers (#8, #9).** The bank bit changes together with the toggle
   and has one register less in its path, so it is settled when the pulse arrives, but this is not enforced by construction. A safer
   design sends the bank number inside one handshake.
5. **No reset in the pixel domain; the result is never cleared.** After the HDMI input is lost, the last digit stays on screen;
   after a resolution change the pipeline re-syncs at the next start of frame (a long gap with no valid pixels), and the first image
   after that can be partial.
6. **No `set_max_delay -datapath_only` on the crossings.** They are covered by `set_clock_groups -asynchronous` only, so their routing
   delay is unconstrained. They work at these clock rates (timing met, board verified); the usual practice is a max-delay of about one
   destination clock period.

Each of these is a candidate for a future change; none was seen to fail in simulation or on the board.
