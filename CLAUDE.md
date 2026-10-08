# CLAUDE.md — Real-Time Edge AI Video Processor on FPGA

> This file is the permanent instruction file for this project. Claude Code reads it at the start of every session.
> Read ALL of it before doing anything. If anything here is unclear or seems wrong, ASK the user. Do not guess.

---

## 0. Who you are working with (read first)

- The user is a **beginner FPGA student** (previous project: ultrasonic sensor on FPGA with output in PuTTY). They also do a team FPGA project at KCCI (soft CPU + I2C/SPI). **This project is separate: it is a solo CV/portfolio project.**
- The user's English is intermediate. **Always talk to the user in simple, short English.** Avoid jargon. When you must use a technical word, explain it in one simple sentence the first time.
- The user learns by doing. They must be able to **explain every part of this project in a job interview.** So you are a teacher as well as an engineer:
  - After finishing each module, give a short plain-English explanation: what it does, why it is designed this way, and one thing an interviewer might ask about it.
  - Add every new concept to `docs/LEARNING.md` (a simple glossary + interview Q&A).
- The user has limited time with the board. Prefer steps that give a **visible result on the board early**.

---

## 1. Project goal (what we are building)

**CV name:** Real-Time Edge AI Video Processor on FPGA
**Repo name:** `fpga-edge-ai-video`

**One-sentence summary:** Live HDMI video goes into the Zybo Z7 board. A small neural network (CNN) running in **hand-written SystemVerilog hardware** recognizes a handwritten digit (0–9) inside a box in the middle of the screen. The result is drawn on top of the live video and sent out to a monitor, at full frame rate, with no frame buffer delay.

**Why this project (keep this in mind for every decision):**
1. It shows **high-speed real-time data processing**: 720p60 video, about 1.8 Gbit/s of pixel data, processed live with zero dropped frames.
2. It shows **edge AI hardware acceleration**, a strong industry trend (cars, smart cameras, robots).
3. It shows standard industry skills: RTL design, clock domain crossing (CDC), AXI bus, bare-metal C on ARM, verification against a golden model, timing closure, and measured benchmarks.
4. It must produce **real, measured numbers** for the CV and a **demo video** for GitHub/LinkedIn.

**Demo the user will show:** Laptop (HDMI out) → Zybo Z7 HDMI RX → FPGA processing → Zybo Z7 HDMI TX → monitor. The laptop shows a drawing app (for example, Paint with a thick pen). The user draws a digit inside the on-screen box. The monitor shows the live video with a green box, the predicted digit, a confidence bar, and a small "what the AI sees" 28×28 preview in the corner.

---

## 2. Hardware and tools

### Hardware the user has
- Digilent **Zybo Z7** (variant **-10 or -20: NOT CONFIRMED YET** — see Phase 0)
- Laptop/PC with HDMI output (video source)
- Monitor with HDMI input
- 2 HDMI cables
- Micro-USB cable (power + JTAG programming + UART)
- PC with Vivado installed (version to be checked in Phase 0)

Optional, later only: Digilent Pcam 5C camera (only for the Zybo Z7-20; Digilent's Pcam demo is for the -20).

### Board facts (verified from Digilent documentation)
| | Zybo Z7-10 | Zybo Z7-20 |
|---|---|---|
| Chip | XC7Z010-1CLG400C | XC7Z020-1CLG400C |
| LUTs | 17,600 | 53,200 |
| Flip-flops | 35,200 | 106,400 |
| Block RAM | 270 KB | 630 KB |
| DSP slices | 80 | 220 |

- Both variants have an **HDMI sink (RX/input) port** and an **HDMI source (TX/output) port**, plus a dual-core ARM Cortex-A9 (the "PS", Processing System) with 1 GB DDR3.
- Speed grade is **-1**. **Target resolution is 1280×720 @ 60 Hz (pixel clock 74.25 MHz).** Do NOT target 1080p: Digilent says 1080p is not fully supported on this board because the 5× serial clock (742.5 MHz) is beyond the -1 speed grade spec. Forum reports also say the Z7-10 needs the TMDS clock range set below 80 MHz to build. 720p fits that.
- Digilent's own HDMI demo defaults the input to 720p through the EDID data in its hardware design.
- Digilent recommends the Z7-20 for video processing. **The design must still fit the Z7-10** if that is what the user has (the CNN below is small on purpose).

### HDMI IP
- Use Digilent's **`dvi2rgb`** (HDMI/DVI input → parallel RGB + pixel clock) and **`rgb2dvi`** (parallel RGB → HDMI/DVI output) IP cores from Digilent's `vivado-library` GitHub repository. Use the release that matches the installed Vivado version.
- Reference design to study (do not copy blindly): Digilent "Zybo Z7 HDMI Input/Output Demo" (branches `10/HDMI/master` and `20/HDMI/master` in the `Digilent/Zybo-Z7` repo; latest release is for Vivado 2024.1). That demo uses VDMA frame buffers in DDR. **Our design does NOT use a frame buffer for the main video path** (we want minimum latency); we stream pixels straight from `dvi2rgb` to `rgb2dvi`.
- Pin constraints: start from Digilent's official Zybo Z7 master XDC file (`Digilent/digilent-xdc` repo). Double-check HDMI RX hot-plug-detect (HPD) and DDC (I2C for EDID) pins, and HDMI TX pins, against the master XDC and the reference manual. **Never invent pin numbers.**
- Known gotchas to check (verify each against the IP documentation, do not assume):
  - The HDMI source (laptop) only sends video if HPD is driven and EDID is readable over DDC.
  - Digilent's video IPs use a non-standard color channel order on the 24-bit bus (an R-B-G ordering, not R-G-B). Confirm with a color-bar or solid-color test.
  - The laptop display must be set to 1280×720 @ 60 Hz (duplicate/mirror or extended display).

### Software tools (to be confirmed in Phase 0)
- **Vivado** (free edition supports both Zybo Z7 variants) and **Vitis** for bare-metal C. Note: Digilent says that for their 2024.1+ releases they support **Vitis Classic mode** only.
- **Python 3** with PyTorch (or similar) and NumPy for training and the golden model.
- **Simulator:** prefer Verilator or Icarus Verilog with **cocotb** (Python testbenches, very common in industry). If those are not available on the user's OS, use Vivado's built-in simulator (xsim) with SystemVerilog testbenches. Decide in Phase 0 and record it in `PROGRESS.md`.
- **Git + GitHub.**

---

## 3. System architecture (target design)

```
 Laptop HDMI out (1280x720 @ 60 Hz)
        |
        v
+---------------------------------------------------------------------------------+
| Zybo Z7  (Programmable Logic = PL)                                              |
|                                                                                 |
|  dvi2rgb ──► [pixel clock domain, 74.25 MHz] ───────────────────────────────►   |
|   (HDMI RX)    |                                                         rgb2dvi|──► Monitor
|                |   1. Pass-through video (RGB, sync signals)               (TX) |
|                |   2. ROI tap: grayscale + 8x8 block average               ▲    |
|                |      -> 28x28 image into ROI buffer (dual-port BRAM)      |    |
|                |   3. Overlay: green box, predicted digit, confidence  ────┘    |
|                |      bar, 28x28 "AI view" preview (scaled up)                  |
|                |                                                                |
|          ROI buffer + frame-done / result handshake  (CLOCK DOMAIN CROSSING)    |
|                |                                                                |
|  [accelerator clock domain, e.g. 100 MHz]                                       |
|      CNN accelerator (hand-written SystemVerilog):                              |
|      conv -> ReLU -> maxpool -> conv -> ReLU -> maxpool -> fully-connected      |
|      int8 x int8 MACs, int32 accumulators, fixed-point requantization           |
|      weights in BRAM/ROM (loaded from .mem files generated by Python)           |
|                |                                                                |
|  AXI-Lite control/status registers  <──────────────►  ARM Cortex-A9 (PS)        |
|  (enable, ROI position, invert, threshold, prediction, confidence,              |
|   latency counter, frame counter, test-image injection, ROI readback)           |
+---------------------------------------------------------------------------------+
                                                    |
                                    UART (USB) ──► PC terminal (PuTTY): stats, logs,
                                                   ROI dumps for dataset collection
```

### Key design decisions (do not change without asking the user)
1. **No frame buffer in the main video path.** Pixels stream in and out with only a few clock cycles of delay. The AI result for frame N is drawn on frame N+1 (normal and acceptable, say so in the README).
2. **The CNN accelerator is hand-written SystemVerilog.** Do NOT use HLS, FINN, hls4ml, or Vitis AI for the core accelerator. Reason: the CV must show RTL design skill. (A comparison against an HLS version can be a stretch goal later.)
3. **Two clock domains minimum:** pixel clock (from `dvi2rgb`) and accelerator clock. All crossings must use proper CDC techniques (dual-port BRAM + synchronized handshake, 2-flop synchronizers for single bits, pulse synchronizers for events). Document every crossing in `docs/CDC.md`.
4. **Integer-only inference.** The Python integer golden model is the specification. The hardware must match it **bit-exactly**.
5. **Region of interest (ROI):** default 224×224 pixels at the center of the 1280×720 frame (x = 528..751, y = 248..471). Downsample by averaging 8×8 blocks → 28×28 grayscale. ROI position must be adjustable through AXI-Lite registers.
6. **Default CNN** (small enough for the Z7-10; adjust only with a documented reason):
   - Input 28×28×1 (uint8)
   - Conv 3×3, 8 channels, ReLU → 26×26×8 → MaxPool 2×2 → 13×13×8
   - Conv 3×3, 16 channels, ReLU → 11×11×16 → MaxPool 2×2 → 5×5×16
   - Fully connected 400 → 10
   - About 5,000 int8 weights (a few KB) and about 190,000 MACs per image
   - With 8 parallel MACs at 100 MHz this is roughly 0.25 ms per image, far below one frame time (16.7 ms), so **inference can run on every frame.**
   - Target: ≥ 97% accuracy on the MNIST test set after int8 quantization (measured in Python AND on the real hardware).
   - Parallelism (number of MACs) must be a SystemVerilog parameter, so we can show a speed vs. resources trade-off table.
7. **Quantization scheme:** symmetric int8 weights (per-tensor to start), uint8 activations, int32 accumulators, requantization with an integer multiplier + right shift (gemmlowp/TFLite style). Write the exact formulas in `docs/QUANTIZATION.md` before writing any RTL for it.
8. **Domain gap fix:** MNIST is white digits on a black background, centered. The live input is dark pen on a white screen. The hardware preprocessing must support an invert option and a threshold (AXI-Lite registers). Train with augmentation (shift, scale, stroke thickness). Later, capture real ROI images from the board (ARM reads the ROI buffer and sends it over UART) and fine-tune with them. Report accuracy on these real captures separately from MNIST accuracy.
9. **Test-image injection mode:** the ARM can write a 28×28 test image directly into the ROI buffer and read back the prediction. This lets us measure **hardware accuracy on the full MNIST test set on the real board**, which is a strong CV number.

---

## 4. Phases and milestones

Work **one phase at a time.** Each phase ends with a milestone the user can see or test. At the end of each phase: update `PROGRESS.md`, update `docs/LEARNING.md`, commit, push, create a git tag (`phase-N-done`), and give the user a short plain-English summary.

**Rule:** a phase is done only when there is **evidence**: a passing simulation log, a build report, or the user confirming a board test. Never mark something done based on "it should work".

### Phase 0 — Setup and environment check
- Ask the user to confirm: **board variant (look at the board: Z7-10 or Z7-20)**, operating system, Vivado/Vitis version installed, whether Python/Git are installed, and their GitHub username and repo URL (or help them create the repo).
- Check which simulators are available (Verilator, Icarus, cocotb, xsim). Install what is missing if the user agrees.
- Create the repo structure (Section 6), `.gitignore` for Vivado/Vitis outputs, `README.md` (placeholder), `PROGRESS.md`, `docs/LEARNING.md`.
- **Milestone:** repo pushed to GitHub, environment recorded in `PROGRESS.md`.

### Phase 1 — HDMI pass-through
- Build a Vivado project **from Tcl scripts** (reproducible; no hand-clicked project committed): Zynq PS (for clocks and UART), `dvi2rgb`, `rgb2dvi`, constraints.
- Video goes straight from input to output at 720p60.
- ARM prints "hello" over UART.
- **Milestone:** the laptop screen appears on the monitor through the FPGA. The user confirms with a photo or by telling you.

### Phase 2 — Pixel pipeline: overlay and grayscale (no AI yet)
- Write SystemVerilog modules: sync/position counter (x, y from the video timing signals), ROI box overlay, simple text/digit drawing with a small font ROM, grayscale conversion.
- Verification: a Python script turns a PNG into a simulated video stream → run simulation → turn the output back into a PNG → compare against a Python reference. Commit before/after images to `docs/images/`.
- **Milestone:** a green box and a fixed test digit are drawn on the live video on the monitor.

### Phase 3 — Machine learning golden model (Python only)
- Train the default CNN on MNIST with augmentation. Quantize to int8.
- Write an **integer-only NumPy inference** that follows `docs/QUANTIZATION.md` exactly. Check that it matches the quantized framework model, and report float vs. int8 accuracy.
- Export weights, biases, and requantization constants as `.mem` files, plus test vectors (input image → every layer's output → final prediction) for the RTL testbenches.
- **Milestone:** `ml/` folder with training script, integer golden model, exported weights, accuracy report.

### Phase 4 — ROI capture, downsampling, and CDC
- ROI tap in the pixel domain: grayscale → optional invert/threshold → 8×8 block average → 28×28 written into a dual-port BRAM.
- Frame-done handshake from the pixel domain to the accelerator domain (properly synchronized).
- AXI-Lite readback of the ROI buffer, plus a C program on the ARM that dumps ROI images over UART and a Python script on the PC that saves them as PNG.
- Show the 28×28 "AI view" preview, scaled up, in a corner of the output video.
- **Milestone:** the user sees the AI-view preview on the monitor and can save ROI captures to the PC. `docs/CDC.md` written.

### Phase 5 — CNN accelerator RTL
- Hand-written SystemVerilog: MAC array (parameterized number of MACs), conv engine, ReLU, maxpool, fully-connected engine, requantization unit, argmax + confidence, and a controller FSM.
- Build module by module. **Every module gets a self-checking testbench** that compares against the Python golden model test vectors.
- Final check: the full accelerator matches the golden model bit-exactly on at least 1,000 MNIST test images in simulation.
- **Milestone:** simulation report showing 1,000/1,000 bit-exact matches, plus cycles per inference.

### Phase 6 — Full system integration
- Connect accelerator + ROI buffer + overlay + AXI-Lite register block. Bare-metal C on the ARM: configure the registers, print prediction, confidence, latency, and FPS over UART.
- Test-image injection mode working.
- Close timing (no negative slack). If timing fails, find the critical path, fix it, and **record the fix in `docs/TIMING.md`** (this is a great interview story).
- **Milestone:** the user draws a digit on the laptop and the monitor shows the correct prediction live.

### Phase 7 — Measure and benchmark (the CV numbers)
Measure and record in `docs/RESULTS.md`, with how each number was measured:
- Hardware accuracy on the full MNIST test set (via injection mode), and accuracy on real captured ROI images.
- Inference latency (cycles and microseconds, from a hardware cycle counter).
- Frame rate kept (60 FPS with zero dropped frames) and pixel throughput (Gbit/s).
- Video pipeline latency (in pixel clocks).
- **Software baseline:** the same integer model in C on the ARM Cortex-A9 → speedup factor.
- Resource use (LUT, FF, BRAM, DSP) and estimated power from Vivado reports, for at least 2 values of the MAC-parallelism parameter (speed vs. area table).
- Worst negative slack / max clock frequency.
- **Milestone:** results table complete. **Never write a number that was not actually measured.**

### Phase 8 — Polish for CV and GitHub
- README: one-line pitch, demo GIF/video link, block diagram, results table, how to build, how it works, what I would improve next.
- Help the user record a short demo video (what to show, in what order).
- Write 3–4 CV bullet points using the real numbers, and a short LinkedIn post draft.
- **Milestone:** public repo looks professional, CV bullets ready.

### Stretch goals (only after Phase 8, only if the user wants)
- Pcam 5C camera input (Z7-20 only).
- More classes (for example letters with EMNIST) or a slightly bigger model.
- An HLS version of one layer for comparison.
- Per-channel quantization and its accuracy gain.

---

## 5. Model and effort selection (Claude must decide and tell the user)

You cannot change your own main model or effort level. Only the user can, by typing commands. So **at the start of every phase, and whenever the type of work changes, put this line at the top of your reply:**

> **Recommended setting:** `/model <name>` and `/effort <level>` — <one short reason>

Then continue only if the current setting is already right. If a switch is needed, stop after the recommendation and wait for the user to switch and say "continue".

Use this table:

| Type of work | Model | Effort |
|---|---|---|
| Planning a phase, architecture decisions, CDC design, quantization math | `opus` | `high` |
| Hard debugging (no video on the monitor, timing failures, simulation mismatches you could not fix in 2 tries) | `opus` | `xhigh` |
| Writing RTL modules and their testbenches | `opus` | `medium` |
| Python training/golden model, Tcl build scripts, C drivers, helper scripts | `sonnet` | `medium` |
| README, docs, PROGRESS.md, LEARNING.md, small edits | `sonnet` | `low` |
| A very long, very hard autonomous task where Opus keeps failing | `fable` | `high` — **only suggest this if the user agrees first**, because Fable may use paid usage credits on some plans |

For subagents you start yourself (for example, searching documentation or reading big log files), you may set their model directly: use `haiku` or `sonnet` for simple searches and summaries, `opus` for code review of RTL.

Project subagents live in `.claude/agents/` (each has its own model): `log-reader` (haiku: facts from long logs/reports), `docs-writer` (sonnet: README/LEARNING/CV drafts from RESULTS.md facts), `rtl-reviewer` (opus: RTL/CDC/testbench review before a phase is called done). The main session briefs them fully (they start with no context), checks what they return, and never lets them invent numbers.

Do not switch-recommend too often. One recommendation per phase or per change in work type is enough.

---

## 6. Repository structure

```
fpga-edge-ai-video/
├── CLAUDE.md               # this file
├── README.md               # public project page (Phase 8)
├── PROGRESS.md             # running log: what is done, what is next, decisions, problems
├── HANDOVER.md             # created/updated when the user changes account (Section 9)
├── docs/
│   ├── LEARNING.md         # glossary + interview Q&A for the user
│   ├── QUANTIZATION.md     # exact integer math the hardware follows
│   ├── CDC.md              # every clock domain crossing and how it is made safe
│   ├── TIMING.md           # timing problems found and how they were fixed
│   ├── RESULTS.md          # all measured numbers and how they were measured
│   └── images/             # diagrams, screenshots, simulation before/after images
├── rtl/                    # SystemVerilog source
├── tb/                     # testbenches (cocotb or SV)
├── ml/                     # Python training, integer golden model, weight export
├── constraints/            # .xdc files
├── scripts/                # Tcl build scripts, Python helpers (PNG <-> video stream, UART capture)
└── sw/                     # bare-metal C for the ARM (Vitis)
```

Never commit Vivado/Vitis generated folders (`.Xil`, `*.cache`, `*.runs`, `*.gen`, `*.sim`, `*.ip_user_files`, Vitis workspaces, logs). Commit only sources, scripts, constraints, and small reports/images needed for documentation. Bitstreams go in GitHub Releases, not in git history.

---

## 7. Working rules

1. **Ask before big decisions** (changing the architecture, the CNN, the tools, or anything in "Key design decisions"). Small implementation details: decide yourself and note them in `PROGRESS.md`.
2. **Physical steps belong to the user.** Programming the board, plugging cables, looking at the monitor: give the user short numbered steps, then wait for their result. You may run Vivado/Vitis in batch mode and program the board from the command line if it is connected to this computer, but always tell the user first and ask them to report what the monitor shows.
3. **No fake results.** Never invent pin numbers, register addresses, measurements, or accuracy numbers. If you are not sure about a fact (IP behavior, a Vivado option), check the official documentation or ask.
4. **Verify before moving on.** Simulate before building. Build before asking the user to test on the board.
5. **Small steps, frequent commits.** Clear commit messages. Push to GitHub at least at every milestone.
6. **Keep `PROGRESS.md` always up to date** (after every work session, not only at milestones). It must always contain: current phase, what works, what is in progress, open problems, decisions made, and the exact next step. This makes account changes and new sessions easy.
7. **Teach.** After each module: a short simple explanation for the user and an update to `docs/LEARNING.md`. If the user asks "why?", answer simply, with an example.
8. **Code quality:** readable SystemVerilog, consistent naming (`clk_pix`, `clk_acc`, `rst_n`, `_q` for registers), a comment header in every file, parameters instead of magic numbers, no latches, synchronous logic, every clock crossing documented.
9. **If stuck after 2 attempts on the same problem:** stop, explain the problem simply, list what you tried, and recommend a model/effort change (Section 5) or ask the user for information (for example a photo of the monitor or a log file).

---

## 8. Definition of "project finished"
- Live demo works: drawing a digit on the laptop shows the correct prediction on the monitor at 60 FPS.
- Accelerator matches the golden model bit-exactly in simulation (≥ 1,000 images).
- Hardware accuracy on the MNIST test set measured on the board.
- `docs/RESULTS.md` complete with real measurements, including the speedup vs. ARM software.
- Timing closed with no negative slack.
- README, demo video, and CV bullets done.

---

## 9. HANDOVER PROTOCOL (account change) — IMPORTANT

The user may switch to a different Claude account. A new account will NOT have this conversation's history. Only the files in this folder (and on GitHub) carry over.

**Trigger:** when the user says anything like "I want to change account", "change account", "switch account", "handover", "make handover", or "ganti akun" — do ALL of the following immediately:

1. **Finish or safely pause** the current small task (do not leave half-edited files). If something is broken, say so clearly.
2. **Update `PROGRESS.md`** fully.
3. **Write `HANDOVER.md`** (overwrite the old one) with ALL of these sections, very detailed and specific (file names, module names, numbers, commands):
   1. **Project summary** — 5 lines: what the project is and the goal.
   2. **User profile** — beginner, simple English, solo CV project, teaching mode, board variant, OS, tool versions.
   3. **Current status** — current phase; each phase marked done / in progress / not started, with evidence (test logs, user-confirmed board tests).
   4. **What works right now** — exactly what the user can see on the board today.
   5. **Work in progress** — what was being done at the moment of handover, which files are touched, and what is unfinished.
   6. **Open problems and bugs** — symptoms, what was tried, current guesses.
   7. **Decisions made** — every decision that differs from or adds to CLAUDE.md, with the reason.
   8. **File map** — every important file and what it does (rtl, tb, ml, scripts, sw, constraints, docs).
   9. **How to build and test** — exact commands for simulation, Vivado build, Vitis build, programming the board, UART settings (115200 baud, no flow control).
   10. **Measured results so far** — numbers already measured (or "none yet").
   11. **Next steps** — the next 3–5 concrete tasks, in order, with the very first command or action.
   12. **Recommended model/effort** for the next task.
   13. **Git state** — branch, last commit hash and message, last tag, whether everything is pushed.
4. **Commit and push** everything (including `HANDOVER.md`) to GitHub. Confirm the push worked.
5. **Print a ready-to-paste "new account prompt"** in a code block for the user. It must tell the new Claude to: read `CLAUDE.md`, then `HANDOVER.md`, then `PROGRESS.md`; summarize the project status back to the user in simple English; confirm the next step with the user before writing code; and follow all rules in `CLAUDE.md`. Include the GitHub repo URL and the local folder path.
6. Tell the user in simple words what to do: (a) make sure the project folder is on the computer (or clone it from GitHub), (b) log in to Claude Code with the new account, (c) open Claude Code in the project folder, (d) paste the prompt.

The handover must be detailed enough that a new Claude with **zero memory** can continue without asking the user to re-explain anything.
