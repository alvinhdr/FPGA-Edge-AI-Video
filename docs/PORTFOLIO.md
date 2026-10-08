# Portfolio texts (CV, LinkedIn, YouTube, interview pitch)

Ready to copy. Every number is from [RESULTS.md](RESULTS.md). Change only the wording, not the numbers.
Be ready to explain each sentence: [LEARNING.md](LEARNING.md) has the glossary and interview Q&A for every part.

---

## CV: project entry

**Real-Time Edge AI Video Processor on FPGA** | SystemVerilog, Vivado/Vitis, Zynq-7000 (Zybo Z7-10), C, Python/PyTorch | github.com/alvinhdr/FPGA-Edge-AI-Video

Pick 3 or 4 of these:

- Designed and verified a hand-written SystemVerilog CNN accelerator (int8 weights, parameterized 1 to 16 MAC lanes) on a Zynq-7010 that classifies a handwritten digit in **240 &micro;s, 9.6x faster than the same integer model in C on the on-chip ARM Cortex-A9** (`-O2`), using 15 % of the device's LUTs and 10 DSPs.
- Built a **live 720p60 HDMI video pipeline with no frame buffer** (7 pixel clocks, 94 ns latency) that overlays the AI result on the picture; measured **60.00 FPS with 0 skipped frames** over 60 s, with the CNN running on every frame.
- Verified the hardware **bit-exact against a Python integer golden model**: 10,000 / 10,000 MNIST test images matched on the real board (97.96 % accuracy), plus self-checking testbenches and mutation tests for the clock-domain-crossing logic.
- Closed timing at 100 MHz and 74.25 MHz across three asynchronous clock domains (pixel clock, accelerator clock, board clock) with documented synchronizers for every crossing; fixed three critical paths one by one.
- Found a **domain gap** (98 % on MNIST but 79 % on my own mouse-drawn digits), captured 140 real images from the live video, and fine-tuned the quantized model: **79 % to 94 %** on unseen drawings (2-fold cross-validation), with the full export-simulate-rebuild-board loop repeated and re-verified.
- Wrote bare-metal C (AXI-Lite drivers, UART tools, MNIST benchmark over serial) and Tcl/Python build scripts so the whole project rebuilds from source in batch mode.

---

## LinkedIn post (draft)

I built a small AI chip... in an FPGA.

My laptop sends live HDMI video into a Zybo Z7-10 board. Inside the FPGA, a neural network that I wrote in SystemVerilog (not HLS, not a ready-made IP) reads the handwritten digit in a box on the screen. The answer is drawn on the live video and sent to the TV, at 60 frames per second, with no frame buffer.

What I measured on the real board:
- 60.00 FPS, 0 skipped frames, the CNN runs on every frame
- 240 &micro;s per image, 9.6x faster than the same model in C on the board's ARM CPU
- 97.96 % on the 10,000 MNIST test images, and the hardware matched my Python golden model bit for bit on every image

What I learned the hard way: my first model was 98 % on MNIST but only 79 % on digits I drew myself. The hardware was fine; the data was different. After fine-tuning on 140 captures from the live video it reached about 94 % on drawings it had not seen. I also wrote down the limits (one person's drawings, a plain-C ARM baseline), because they matter.

Video: https://youtu.be/mclvHZH5C0E
Code and all results: https://github.com/alvinhdr/FPGA-Edge-AI-Video

#FPGA #EdgeAI #SystemVerilog #Zynq #DigitalDesign #EmbeddedSystems

(Make the repo public before you post this link.)

---

## YouTube description (draft)

Real-Time Edge AI Video Processor on FPGA.
Laptop (HDMI 720p60) -> Digilent Zybo Z7-10 -> TV. A CNN written in SystemVerilog recognizes the handwritten digit in the green box and draws the result on the live video: no frame buffer, 60 FPS, 0 skipped frames.
On screen, left to right: what the AI sees (28x28), the box, the prediction and a confidence bar. An empty box shows nothing (minimum-confidence filter).
Measured: 240 microseconds per image, 9.6x faster than the on-chip ARM CPU, 97.96 % on MNIST (bit-exact vs. a Python golden model), about 94 % on my own drawings.
Code, results and how everything was measured: https://github.com/alvinhdr/FPGA-Edge-AI-Video

---

## 30-second interview pitch

"I built a live video AI processor on an FPGA. HDMI video goes through the board with only a few clocks of delay, and a CNN that I wrote in SystemVerilog recognizes a handwritten digit in a box and draws the answer on the video at 60 FPS. The CNN takes 240 microseconds and is about 10 times faster than the board's own ARM CPU running the same integer model. I checked it against a Python golden model and on the real board it matched all 10,000 test images exactly. The part I learned most from was the data: my first model was 79 % on my own drawings, so I captured real images from the video, fine-tuned, and measured 94 % with cross-validation. I also know the limits: one person's drawings and a plain-C baseline."

Questions to prepare (answers are in [LEARNING.md](LEARNING.md)): clock domain crossing, why bit-exact, quantization (zero point 0, requantization), why 8 MACs, how the 7-clock video latency comes about, what the critical-path fixes were, and the 1080p/EDID bug.

Honest note for interviews: if you are asked how you built it, say what you did yourself and where you used an AI assistant, and be able to explain every module on your own.
