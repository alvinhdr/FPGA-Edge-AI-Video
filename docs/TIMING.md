# TIMING — Problems found and how they were fixed

Each entry: symptom, cause, fix, and what I learned.

## 1. DRC REQP-1712: PLL input driven by a global buffer (Phase 1)

**Symptom.** Implementation stopped before placement:
`[DRC REQP-1712] Unsupported PLLE2_ADV connectivity ... with COMPENSATION mode ZHOLD must be driven by a clock capable IO.`

**Cause.** The 125 MHz board clock `sysclk` was used in two places: as the input of the
Clocking Wizard PLL, and directly by an LED counter in the fabric. To drive fabric flip-flops,
Vivado inserts a global clock buffer (BUFG). The PLL then saw `IBUF -> BUFG -> PLL`. In ZHOLD mode
(the default, it lines up the PLL output with the clock at the input pin) the PLL input must come
straight from a clock-capable pin, not through a BUFG.

**Fix.** `sysclk` now drives only the PLL. The PLL makes a second output, `clk_sys` (125 MHz), and
all our own logic on the board clock uses `clk_sys`.

**Lesson.** An input clock pin should feed one clock block (MMCM/PLL). Make all the clocks your
logic needs from that block's outputs.

## 2. Two clocks on one pin -> safe crossing reported as a timing failure (Phase 1)

**Symptom.** WNS = -8.353 ns on 1 endpoint, path `PixelClk_int -> clk_out2_clk_wiz_ref`. This is the
`pix_locked` 2-flop synchronizer, a crossing that is asynchronous on purpose.

**Cause.** The Clocking Wizard IP has its own XDC with `create_clock` on its input pin. My XDC also
created a clock on the same pin with `-add`, so two clocks existed (`clk_out2_clk_wiz_ref` and
`clk_out2_clk_wiz_ref_1`). The PLL outputs that came from the IP's clock were not in my
`set_clock_groups -asynchronous` group, so Vivado tried to time the crossing as if the clocks were related.

**Fix.** Removed `-add`. My `create_clock` now replaces the IP's definition, so there is one clock
family on `sysclk` and the asynchronous group covers all of it.

**Lesson.** Read the inter-clock table in the timing report. A huge negative slack on a crossing
you know is asynchronous usually means a constraint problem, not a logic problem. Never "fix" it
by making logic faster.

**Update (Phase 2).** Replacing the IP's clock still gave CRITICAL WARNINGs
(`Constraints 18-1055/1056: Clock 'sys_clk_pin' completely overrides clock 'sysclk'`).
Final fix: do not create any clock on `sysclk` in our XDC. The clk_wiz IP already creates the
8.000 ns clock on its input, and our clock group refers to it by pin:
`get_clocks -include_generated_clocks -of_objects [get_ports sysclk]`. One clock, no override.

## 3. Clock group "found no clock" for the PS clock (Phase 4)

**Symptom.** `CRITICAL WARNING: [Vivado 12-4739] set_clock_groups: No valid object(s) found for
'-group [get_clocks -include_generated_clocks clk_fpga_0]'`.

**First guess (wrong).** I thought Vivado read our XDC before the PS block's XDC, so the clock did
not exist yet and the crossings were not constrained. I set `PROCESSING_ORDER LATE`; the warning stayed.

**Real cause.** Looking at each log separately: the warning is only in the **synthesis** log, the
**implementation** log has none, and `report_clocks` shows `clk_fpga_0` exists there. The block
design (with the PS) is synthesized out-of-context, so during top-level synthesis the PS clock does
not exist. In implementation, where timing is signed off, the clock group was applied correctly the
whole time. Timing was never "passing by luck".

**Fix.** Moved the clock groups into `constraints/zybo_z7_10_impl.xdc` with `USED_IN_SYNTHESIS false`.
Kept `PROCESSING_ORDER LATE` (our XDC refers to IP-created clocks, so reading it last is correct anyway).

**Lesson.** Check which step (synthesis or implementation) a warning comes from before drawing a
conclusion, and verify a guess with `report_clocks` instead of assuming. My first explanation was
wrong; checking the logs separately found the real cause.

## 4. CNN accelerator at 100 MHz: three critical paths, fixed one by one (Phase 5)

Out-of-context build of `rtl/cnn_top.sv` (P = 8) with `scripts/synth_cnn.tcl`. Each fix was
re-verified bit-exact with `scripts/sim_cnn.py` before the next build.

| Step | WNS | Critical path (from the timing report) | Fix |
|---|---|---|---|
| 1 | **-2.019 ns** | `cnn_argmax`: `top1 - top2`, `* MC`, `+ 2^(SC-1)` in ONE clock: 19 logic levels (13 CARRY4) | split into 3 clocks (S_DIFF, S_MUL, S_RND). Cost: +2 clocks per inference |
| 2 | **-1.350 ns** | block-RAM read (no output register) → activation mux → multiplier in LUTs → 32-bit accumulate, one clock, 14 levels; only 4 DSPs used | register the MAC inputs after the memories; 2-stage MAC (multiply register, then accumulate) = DSP48 structure. Now 12 DSPs, LUTs halved (2328 → 1176). Controller DRAIN 2 → 4. Cost: +2 clocks per pooled position (23,523 → 23,965 cycles) |
| 3 | **-0.814 ns** | controller input address `ci*HW*HW + row*HW + col` with layer-dependent HW: Vivado built real multipliers (2 DSP48 in the path) | one address formula per layer with constant sizes (28, 13, 169) → shifts/adds; same for the weight address |
| done | **+0.507 ns** | requant input mux → DSP (3 levels) | — |

Result (P = 8): 1211 LUT, 966 FF, 3.5 BRAM, 10 DSP, 23,965 cycles = 240 us per image.

**Lessons.** (1) Read the path in the timing report, do not guess: each failure was somewhere else.
(2) "Multiply and add in one clock" is the classic slow path; pipeline it the way the DSP48 is
built. (3) Constants matter: the same formula with a variable size needs a multiplier, with a
constant size only an adder. (4) A pipeline stage changes the timing of every flag that travels
with the data; the bit-exact testbench is what makes such changes safe.

## 5. Windows picked 1080p: the overlay was not centered (Phase 6 board test)

**Symptom.** On the board, the green box, AI view and digit appeared in the upper-left part of the
screen, and looked about 2/3 of the size they should have next to the Paint window.

**Wrong first guess.** "Windows display scale is 150 %". The user's settings said 1280x720 and 100 %.

**Real cause.** Windows > Advanced display > "Active signal mode" said **1920 x 1080**, while the
"Desktop mode" said 1280 x 720: the graphics card stretched the desktop and sent a 1080p signal
(148.5 MHz pixel clock). Digilent's EDID (`dgl_720p_cea.data`) also lists 1080p and 1280x1024, so
the laptop was allowed to choose. All our positions (ROI x=528..751, y=248..471) are for a
1280x720 frame, so on a 1080p frame they are up-left of the center. 1080p is also outside the
-1 speed grade (the dvi2rgb MMCM VCO would be 1485 MHz > 1200 MHz).

**Fix.** `scripts/make_edid.py` builds `rtl/edid_720p_only.data`: same vendor ID and 720p timing as
Digilent's file, but 1080p, 1280x1024 and all legacy modes removed (only CEA VIC 4). Product code
changed so Windows treats it as a new monitor. `scripts/build_hw.tcl` overwrites the IP's copy of
`dgl_720p_cea.data` inside `build/` (the submodule is not touched).

**Note.** The EDID is only what the Zybo input port tells the laptop. A monitor plugged directly
into the laptop still uses its own EDID, so gaming at high resolution is not affected.

**Lesson.** When something is "in the wrong place", measure what signal really arrives (active
signal mode), do not assume the setting you see is the signal on the cable.
