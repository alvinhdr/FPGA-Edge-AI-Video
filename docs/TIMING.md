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
