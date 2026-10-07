# CDC — Clock Domain Crossings

Every place where a signal goes from one clock to another, and how it is made safe.

## Clocks in the design

| Clock | Frequency | Source | Used for |
|---|---|---|---|
| `sysclk` | 125 MHz | Board oscillator (Ethernet PHY), pin K17 | Input to `clk_wiz_ref` only |
| `clk_sys` | 125 MHz | `clk_wiz_ref` (PLL) from `sysclk` | LED blink, status synchronizers |
| `clk_ref` | 200 MHz | `clk_wiz_ref` (PLL) from `sysclk` | `dvi2rgb` IDELAYCTRL + EDID emulator |
| `clk_pix` | 74.25 MHz (720p60) | Recovered from the HDMI input by `dvi2rgb` (MMCM) | Whole pixel pipeline, `rgb2dvi` input |
| serial clocks | 371.25 MHz (5x `clk_pix`) | Inside `dvi2rgb` and `rgb2dvi` (MMCM) | TMDS serializer / deserializer only |
| `clk_acc` | 100 MHz (planned, Phase 4+) | PS `FCLK_CLK0` | CNN accelerator, AXI-Lite |

`sysclk`/`clk_sys`/`clk_ref` and `clk_pix` come from **different oscillators** (board vs. laptop), so they are
**asynchronous**: their edges have no fixed relation. This is declared in
`constraints/zybo_z7_10.xdc` with `set_clock_groups -asynchronous`, so Vivado does not try to time
paths between them. That is only safe because every crossing below uses a synchronizer.

## Crossings

| # | Signal | From → To | Type | How it is made safe | Where |
|---|---|---|---|---|---|
| 1 | `pix_locked` | `clk_pix` → `clk_sys` | 1-bit level (status) | `cdc_sync_2ff` (2 flip-flops, `ASYNC_REG`) | `rtl/top.sv` (`u_sync_pix_locked`) |
| 2 | `ref_locked` → `dvi2rgb.aRst_n` | async → `clk_ref`/`clk_pix` | async reset | Reset synchronizers inside `dvi2rgb` (`SyncAsyncReset`) | Digilent IP |
| 3 | `pix_locked` → `rgb2dvi.aRst_n` | `clk_pix` → `rgb2dvi` internal clocks | async reset | Reset synchronizer inside `rgb2dvi` (`SyncAsyncReset`) | Digilent IP |
| 4 | internal lock / reset signals | `clk_ref` ↔ `clk_pix` | 1-bit | `SyncAsync` / `SyncBase` modules inside `dvi2rgb` (false paths in the IP's own XDC) | Digilent IP |

LED outputs and `hdmi_rx_hpd` are slow, human-speed signals: they have a false path in the XDC.

## Planned (later phases)
- ROI buffer: dual-port BRAM, write port on `clk_pix`, read port on `clk_acc`.
- Frame-done event `clk_pix` → `clk_acc`: pulse synchronizer (toggle + 2-flop + edge detect).
- Result (digit, confidence) `clk_acc` → `clk_pix`: handshake, data held stable while the flag crosses.
