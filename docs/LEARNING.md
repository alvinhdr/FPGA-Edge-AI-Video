# LEARNING — Glossary and Interview Q&A

Simple explanations of every concept in this project. Updated after each module.

## Glossary

- **FPGA**: a chip full of small logic blocks that you connect with code. It does many things at the same time (in parallel), unlike a CPU.
- **PL (Programmable Logic)**: the FPGA part of the Zynq chip. Our video and AI hardware live here.
- **PS (Processing System)**: the ARM CPU part of the Zynq chip. It runs C code, sets registers, prints over UART.
- **HDMI RX / TX**: receive (input) and transmit (output) ports for video.
- **720p60**: 1280x720 pixels, 60 frames per second. Pixel clock = 74.25 MHz.
- **CNN**: Convolutional Neural Network. A small program made of filters that recognizes images.
- **Frame buffer**: memory that stores a whole video frame. We do NOT use one in the main path, so latency is very small.
- **ROI**: Region Of Interest. The box in the middle of the screen where the digit is drawn.
- **CDC (Clock Domain Crossing)**: passing data between two parts that use different clocks. It needs special care, or data gets corrupted.
- **xsim**: the simulator inside Vivado. We use it to test our SystemVerilog before putting it on the board.
- **Golden model**: a Python version of the AI that gives the exact right answers. The hardware must match it bit by bit.

- **TMDS**: the way HDMI sends data: 3 data pairs + 1 clock pair, each a fast differential signal. Every 8-bit color becomes a 10-bit code.
- **dvi2rgb / rgb2dvi**: Digilent IP cores. dvi2rgb turns the HDMI signal into normal parallel pixels (24-bit RGB + sync). rgb2dvi does the opposite.
- **Pixel clock (`clk_pix`)**: one clock tick per pixel. 720p60 = 1650 x 750 total pixels (with blanking) x 60 = 74.25 MHz.
- **Serial clock**: 5x the pixel clock (371.25 MHz). With DDR (both clock edges) it sends 10 bits per pixel per channel.
- **Blanking / DE (data enable)**: the video has invisible areas around the picture. DE = 1 means "this is a visible pixel".
- **HSync / VSync**: pulses that mark "new line" and "new frame".
- **EDID**: a small data table the screen gives to the laptop, saying "I support 720p". Read over the DDC wires (I2C).
- **HPD (hot-plug detect)**: a wire that says "a screen is connected". The laptop sends video only when HPD is high.
- **MMCM / PLL**: clock blocks inside the FPGA. They make new clock frequencies from an input clock.
- **IDELAYCTRL**: calibrates the input delay blocks. It needs a 200 MHz reference clock.
- **IOBUF**: a tri-state pin buffer. It lets a pin be both input and output (needed for I2C).
- **Metastability**: when a flip-flop samples a signal exactly while it changes, its output can be "in between" for a short time. A 2-flip-flop synchronizer gives it time to settle.
- **Asynchronous clocks**: clocks from different oscillators. Their edges have no fixed relation, so every signal crossing between them needs a synchronizer.
- **Bitstream (.bit)**: the file that configures the FPGA.
- **XSA**: the hardware description file Vivado gives to Vitis (which peripherals, addresses, and the bitstream).
- **ps7_init**: code that sets up the ARM side (clocks, DDR memory, pins). Normally the boot loader runs it; with JTAG we run it from xsdb.
- **xsdb**: the command-line debugger. It programs the FPGA and loads C programs into the ARM over JTAG.

- **Pipeline (stage)**: work split into steps, one register between each step. Each step takes 1 clock. A new pixel enters every clock, so throughput stays 1 pixel/clock; only the delay (latency) grows. Our pixel pipeline has 4 stages = 4 clocks = 54 ns.
- **Latency**: how long one piece of data takes to go through. **Throughput**: how much data per second.
- **Package (SystemVerilog)**: a file with shared types, constants and functions that many modules import. We keep the pixel color order in one place there.
- **Packed struct**: a group of named signals stored as one bit vector, e.g. `video_t` = {data, de, hs, vs}. Easy to pass through pipeline registers together, so they stay aligned.
- **ROM / $readmemb**: read-only memory. `$readmemb` loads its contents from a text file of binary numbers, both in simulation and in synthesis.
- **Font ROM**: a table of small bitmaps. Each 8-bit row says which pixels of a character are on.
- **Grayscale (luma)**: brightness of a color pixel. We use gray = (77R + 150G + 29B) >> 8, integer weights that sum to 256.
- **Golden / reference model**: a simple program (here Python) that computes the expected output. The hardware output must match it exactly.
- **Bit-exact**: every bit is the same, not just "close".
- **Testbench**: simulation code that drives inputs into the design (the DUT, "device under test") and records or checks the outputs.
- **Plusargs**: command-line options for a simulation (`+gray1`), read with `$value$plusargs`.

## Interview Q&A

**Q: How does your HDMI pass-through work, and how big is the latency?**
A: dvi2rgb decodes HDMI into 24-bit pixels plus sync on the recovered pixel clock. The pixels go straight to rgb2dvi, which encodes them back to HDMI. There is no frame buffer, so the latency is only a few pixel clocks (the serializer/deserializer pipeline), not a whole frame.

**Q: Why did you make the 200 MHz reference clock from the board oscillator and not from the ARM?**
A: The ARM's FPGA clocks only start after software sets up the PS. With the board oscillator, the video path works as soon as the FPGA is programmed. That makes the design simpler to debug and more robust.

**Q: What is a clock domain crossing, and how did you handle it?**
A: A signal that goes from one clock to another, unrelated clock. I declared the clock groups as asynchronous in the constraints, and every crossing goes through a synchronizer, for example a 2-flip-flop synchronizer with the ASYNC_REG attribute for status bits. All crossings are listed in docs/CDC.md.

**Q: Why does the laptop need HPD and EDID?**
A: HPD tells the laptop a screen is connected. The laptop then reads EDID over DDC (I2C) to learn which resolutions the screen supports. dvi2rgb emulates an EDID that says "720p", so the laptop sends 1280x720 at 60 Hz.

**Q: Why use xsim and SystemVerilog testbenches?**
A: Vivado includes xsim, so no extra tools are needed on Windows. The testbenches are self-checking: they compare the hardware output with the Python golden model and print PASS or FAIL.

**Q: Why the Zybo Z7-10?**
A: It is the smaller Zynq board (17,600 LUTs, 80 DSPs). Designing a small CNN that fits it shows careful use of resources.

**Q: How did you debug the HDMI input without a logic analyzer?**
A: I put status signals on LEDs: PLL locked, HDMI input locked (dvi2rgb pLocked), and two blinking counters, one on the board clock and one on the recovered pixel clock. On the PC, Windows showed a new display named "DGL 720P CEA", which is the EDID my design sends. That proved HPD, EDID, and the TMDS lock separately, before connecting the output.

**Q: How do you find the pixel position (x, y) in a video stream?**
A: I count pixels while DE (data enable) is high: x resets at the start of each visible line, y goes up by one per line. I detect a new frame when DE stays low for a long time (vertical blanking is ~49,500 clocks, horizontal blanking only 370). I use DE instead of HSYNC/VSYNC because the sync polarity changes between video modes, but DE is always active-high.

**Q: How did you verify the video pipeline?**
A: Image-based simulation. A Python script turns a test picture into a real 720p stream with blanking and sync, the SystemVerilog testbench plays it through the design in xsim, and Python compares every output pixel of two full frames against a Python reference model, bit-exactly. It also checks that DE/HSYNC/VSYNC come out unchanged, delayed by exactly the pipeline latency. I also checked that the checker catches mistakes (a wrong digit or a box shifted by one pixel makes it fail).

**Q: Why is the ROI box drawn outside the ROI?**
A: The pixels inside the ROI are the AI's input. If the green frame were inside, it would become part of the picture the CNN sees and could confuse it.

**Q: Why must the timing signals go through the same pipeline registers as the pixel data?**
A: If the pixel data is delayed by 4 clocks but DE/HSYNC/VSYNC are not, every pixel is drawn 4 positions off and the picture shifts or tears. Passing them together (one struct) keeps them aligned.

## Quantization (Phase 3)

- **Quantization**: storing numbers as small integers plus a scale: `real = scale × integer`. Our weights are int8 (−127..127), activations uint8 (0..255).
- **Scale / zero point**: the scale says how big one integer step is. The zero point is the integer that means real 0. We use zero point 0 everywhere, so the hardware needs no correction terms.
- **Symmetric quantization**: the range is centered on 0 (−127..127), so the zero point is 0.
- **Per-tensor**: one scale for a whole layer's weights (simplest). Per-channel = one scale per filter (more accurate, stretch goal).
- **PTQ (post-training quantization)**: train in float, then convert to integers. **QAT** = quantization-aware training (simulate the integers during training), used only if PTQ loses too much accuracy.
- **Requantization**: turning a big int32 accumulator back into uint8 for the next layer: `(acc × M + 2^(S−1)) >> S`, then clamp to 0..255. `M` and `S` together mean "multiply by a real number smaller than 1", using only an integer multiply and a shift.
- **Accumulator**: the running sum of products in a MAC (multiply-accumulate). int8 × uint8 products summed over many inputs need ~25 bits.

**Q: Why is ReLU free in your design?**
A: After requantization I clamp the result to 0..255. Clamping at 0 is exactly ReLU, so there is no separate ReLU hardware.

**Q: Why can max-pooling work directly on the uint8 values?**
A: All four values in the window share one scale, and requantization is monotonic (a bigger accumulator never gives a smaller output). So the largest integer is also the largest real value.

**Q: Why no requantization after the last layer?**
A: All 10 outputs share the same scale, so the largest int32 accumulator is the largest logit. The argmax only needs to compare them.

**Q: Why did you write QUANTIZATION.md before the RTL?**
A: It is the specification. The Python golden model and the hardware both implement it, so when they disagree I know which one to fix. It also forced me to check the bit widths (the largest accumulator needs 25 bits signed), which decides the hardware datapath width.
