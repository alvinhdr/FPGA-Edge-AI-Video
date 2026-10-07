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

## Training and the golden model (Phase 3)

- **Data augmentation**: random shift, rotation, scale, stroke thickness and background changes on the training images, so the CNN also works on pictures that are not clean MNIST (the "domain gap" of a live screen).
- **Domain gap**: the difference between the training data (clean MNIST) and the real data (our live ROI). We measure it separately instead of hiding it in one number.
- **Calibration**: running the float model over many images to find the largest value of each layer's output, which sets the activation scale.
- **Golden model**: `ml/golden_int.py`, integer-only. The hardware must give the same bits.
- **Independent cross-check**: `ml/check_golden.py` implements the same spec a second way (PyTorch) and requires identical layer outputs. Two separate implementations agreeing makes a shared bug very unlikely.
- **Test vectors**: input image + every layer output from the golden model, stored as `.mem` files. The Phase 5 testbenches read them and compare.

**Q: Your int8 model has 98.25 % and the float model 98.24 %. Did quantization really lose nothing?**
A: On the 10,000 MNIST test images, int8 and float give the same answer for 99.9 % of images; the 0.01 % difference is noise (a few images flip in both directions). I also checked that no activation saturates at 255, so the activation scale is not clipping anything.

**Q: How do you know the golden model itself is right?**
A: I wrote a second, independent integer implementation with PyTorch's conv/pool/linear functions (exact, because all values stay far below 2^53) and require every layer output to be bit-identical on 2,000 test images. And the accuracy matches the float model, so it computes the right thing, not just a consistent thing.

**Q: Why do you report MNIST accuracy and "real" accuracy separately?**
A: A model can score 98 % on MNIST and fail on the live picture because the input looks different. A single mixed number would hide that. The report keeps clean MNIST, a synthetic stress test, and (later) real captured ROIs and on-board results as separate rows.

**Q: Did anything surprise you in the first board test?**
A: The overlay box was not centered. From its position (27 % instead of 41 % of the width) I worked out that the laptop was sending 1920x1080, not 1280x720: the EDID I used also offered 1080p, so Windows chose it. At 1080p the pixel clock is 148.5 MHz, twice my timing constraint and above the input MMCM's VCO limit, so it only worked by luck. I set the laptop to 720p and noted a custom 720p-only EDID as a fix. Lesson: "it works" is not the same as "it works inside the spec".

## ROI capture and clock domain crossing (Phase 4)

- **ROI capture**: turning the 224x224 box into the 28x28 CNN input while pixels stream by: gray → invert → 8x8 average → optional threshold. Only 28 small accumulators are stored, not the picture.
- **Dual-clock block RAM**: a memory with two ports, each on its own clock. The standard way to move a buffer between clock domains.
- **Ping-pong (double) buffer**: two banks; one is written while the other (complete) one is read. Prevents reading half-old, half-new images ("tearing").
- **Toggle / pulse synchronizer**: send an event as a level change, not a pulse, so a slower clock cannot miss it.
- **Req/ack handshake (bus synchronizer)**: hold a multi-bit value stable, send a request flag across, the other side copies the value and acknowledges. Keeps all bits consistent.
- **AXI4-Lite**: simple ARM bus for registers: separate address/data/response channels with valid/ready handshakes.
- **Memory-mapped registers**: the ARM reads/writes hardware settings like memory addresses (our base 0x43C00000).
- **FSBL / BOOT.bin**: first-stage boot loader. BOOT.bin = FSBL + bitstream + ARM program; with the boot jumper on SD the board starts by itself.
- **Mutation testing**: deliberately breaking the design to prove the testbench can catch the bug.

**Q: How does data get from the pixel clock to the 100 MHz clock in your design?**
A: Three mechanisms. The 28x28 image goes through a dual-clock block RAM with two banks: the pixel side writes one bank while the other side reads the last complete one. The "frame done" event crosses as a toggle through a 2-flop synchronizer with edge detect. Settings from the ARM (ROI position, invert, threshold, freeze) are 33 bits, so they use a request/acknowledge handshake that holds the value stable while it crosses.

**Q: Why not just put 2 flip-flops on each bit of the settings bus?**
A: Each bit can arrive one clock earlier or later than the others, so the receiver can see a value that never existed. I proved it: my CDC testbench passes with the handshake, but a mutant with 2 flops per bit failed with 127 errors, for example seeing 64 while the value went from 127 to 128.

**Q: Your first live test predicted the wrong digit. Why, and what did you do?**
A: The capture showed the reason: part of the Paint toolbar was inside the box (it became a white bar after inversion), and the digit touched the edges, unlike centered MNIST digits. I moved the ROI with a register write (no rebuild) and drew the digit centered at about 2/3 of the box height; then the model predicted correctly. Real captures like these will be used to measure and reduce the domain gap.

**Q: You said timing passed "by luck" and then corrected yourself. What happened?**
A: A clock-group constraint gave a "no objects found" warning. I first guessed a constraint-order problem, but checking the logs separately showed the warning was only in synthesis (where the PS block is a black box); implementation had applied it correctly. I documented both the wrong guess and the real cause in TIMING.md, and moved the constraint to an implementation-only file.
