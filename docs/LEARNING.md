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
