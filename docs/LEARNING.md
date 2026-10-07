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

## Interview Q&A

**Q: Why use xsim and SystemVerilog testbenches?**
A: Vivado includes xsim, so no extra tools are needed on Windows. The testbenches are self-checking: they compare the hardware output with the Python golden model and print PASS or FAIL.

**Q: Why the Zybo Z7-10?**
A: It is the smaller Zynq board (17,600 LUTs, 80 DSPs). Designing a small CNN that fits it shows careful use of resources.
