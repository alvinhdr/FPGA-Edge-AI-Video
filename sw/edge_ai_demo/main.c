/* =============================================================================
 * File   : main.c
 * Project: Real-Time Edge AI Video Processor on FPGA
 * Purpose: Phase 6 ARM program for the full system. The CNN runs in hardware on
 *          every video frame by itself; this program only configures it, prints
 *          the live prediction over the UART (115200 8N1), and offers tests.
 *
 * Commands (one key from the PC, e.g. PuTTY or scripts/capture_roi.py):
 *   p : print the current prediction        s : status
 *   j : injection self-test: the 20 MNIST test images built into this program are
 *       written to the inject RAM, classified by the hardware CNN, and compared
 *       bit-exactly with the golden model (digit + confidence)
 *   c : capture the 28x28 ROI + hardware CNN result ("ROI <1568 hex> HW <digit> <conf>"),
 *       for scripts/capture_roi.py
 *   f : frame-rate test (60 s): frames, inferences, skipped frames, fps
 *   w/a/z/d : move the ROI box up/left/down/right by 8 pixels   x : ROI back to the center
 *   i : toggle invert   t : toggle threshold   + / - : threshold +/- 8
 *   h : help
 * Live output: a "PRED" line every time the predicted digit changes.
 * ========================================================================== */
#include "xil_printf.h"
#include "xparameters.h"
#include "xuartps_hw.h"
#include "sleep.h"
#include "xiltimer.h"
#include "edge_ai_regs.h"
#include "mnist_test_images.h"

#define ROI_X_CENTER 528
#define ROI_Y_CENTER 248
#define ROI_STEP     8

/* Cortex-A9 global timer = CPU clock / 2 (Zynq-7000 TRM); started by the first sleep call. */
#define TIMER_HZ     ((u32)(XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2))

extern void outbyte(char c);

static int key_available(void) { return XUartPs_IsReceiveData(STDIN_BASEADDRESS); }
static char key_read(void)     { return (char)XUartPs_RecvByte(STDIN_BASEADDRESS); }

static void put_hex_byte(u8 v)
{
    static const char hex[] = "0123456789abcdef";
    outbyte(hex[v >> 4]);
    outbyte(hex[v & 0xF]);
}

static void print_prediction(void)
{
    u32 r = eai_rd(EAI_RESULT);
    u32 cyc = eai_rd(EAI_CNN_CYCLES);
    if (!EAI_RESULT_VALID(r)) { xil_printf("PRED none yet\r\n"); return; }
    xil_printf("PRED digit=%u conf=%u/255 latency=%u cycles (%u us) inferences=%u\r\n",
               EAI_RESULT_DIGIT(r), EAI_RESULT_CONF(r), cyc, cyc / EAI_CLK_MHZ, eai_rd(EAI_CNN_COUNT));
}

static void print_status(void)
{
    u32 ctrl = eai_rd(EAI_CTRL);
    u32 roi  = eai_rd(EAI_ROI_POS);
    xil_printf("STATUS id=0x%08x frames=%u inferences=%u cnn_enable=%u inject=%u invert=%u thresh_en=%u thresh=%u roi=(%u,%u)\r\n",
               eai_rd(EAI_ID), eai_rd(EAI_FRAME_CNT), eai_rd(EAI_CNN_COUNT),
               (ctrl >> 3) & 1u, (ctrl >> 4) & 1u, ctrl & 1u, (ctrl >> 1) & 1u,
               eai_rd(EAI_THRESH), roi & 0x7FFu, (roi >> 16) & 0x7FFu);
}

static int wait_frames(u32 n)
{
    u32 start = eai_rd(EAI_FRAME_CNT);
    for (int ms = 0; ms < 500; ms++) {
        if (eai_rd(EAI_FRAME_CNT) - start >= n) return 1;
        usleep(1000);
    }
    return 0;
}

static u32 infer_injected(const unsigned char *img);

/* ROI capture (same protocol as sw/roi_capture, plus the hardware result). The CNN is
 * paused while the ARM reads, because the CNN and the AXI readback share the ROI
 * buffer's read port. Then the captured image is classified by the hardware CNN
 * through the inject RAM, so the PC gets the hardware's answer for EXACTLY this image:
 * "ROI <1568 hex> HW <digit> <conf>". */
static void capture(void)
{
    static u8 buf[EAI_ROI_PIXELS];
    u32 ctrl = eai_rd(EAI_CTRL);

    if (!wait_frames(2)) { xil_printf("ERR no frames (is HDMI video at 1280x720 coming in?)\r\n"); return; }
    eai_wr(EAI_CTRL, (ctrl | EAI_CTRL_FREEZE) & ~EAI_CTRL_CNN_ENABLE);
    usleep(50000);
    while (EAI_RESULT_BUSY(eai_rd(EAI_RESULT))) { }
    for (int attempt = 0; attempt < 3; attempt++) {
        u32 bank_before = eai_rd(EAI_STATUS) & 1u;
        for (int i = 0; i < EAI_ROI_PIXELS; i++) buf[i] = (u8)eai_rd(EAI_ROI_DATA + 4u * (u32)i);
        if ((eai_rd(EAI_STATUS) & 1u) == bank_before) break;
    }
    /* hardware CNN on exactly this image (still paused, inject mode = CNN reads the inject RAM) */
    eai_wr(EAI_CTRL, ((ctrl | EAI_CTRL_FREEZE) & ~EAI_CTRL_CNN_ENABLE) | EAI_CTRL_INJECT);
    u32 r = infer_injected(buf);
    eai_wr(EAI_CTRL, ctrl);

    xil_printf("ROI ");
    for (int i = 0; i < EAI_ROI_PIXELS; i++) put_hex_byte(buf[i]);
    xil_printf(" HW %u %u\r\n", EAI_RESULT_DIGIT(r), EAI_RESULT_CONF(r));
}

/* Frame-rate test: count video frames (ROI captures) and CNN inferences for 60 s, timed
 * with the ARM global timer. Each window starts and ends right after an inference
 * finishes, so no inference is "in flight" when the counters are read. */
static void fps_test(void)
{
    const u32 seconds = 60;
    XTime t0, t1;
    u32 f0, c0, f1, c1, n;

    if (!wait_frames(2)) { xil_printf("ERR no frames (is HDMI video at 1280x720 coming in?)\r\n"); return; }
    xil_printf("FPS test: %u s, do not touch the board...\r\n", seconds);
    n = eai_rd(EAI_CNN_COUNT); while (eai_rd(EAI_CNN_COUNT) == n) { }
    XTime_GetTime(&t0); f0 = eai_rd(EAI_FRAME_CNT); c0 = eai_rd(EAI_CNN_COUNT);
    for (u32 s = 1; s <= seconds; s++) {
        sleep(1);
        if (s % 10 == 0) xil_printf("  %u s\r\n", s);
    }
    n = eai_rd(EAI_CNN_COUNT); while (eai_rd(EAI_CNN_COUNT) == n) { }
    XTime_GetTime(&t1); f1 = eai_rd(EAI_FRAME_CNT); c1 = eai_rd(EAI_CNN_COUNT);

    u32 frames = f1 - f0, infers = c1 - c0;
    u64 ticks = t1 - t0;
    u32 mfps = (u32)(((u64)frames * 1000u * TIMER_HZ + ticks / 2) / ticks);   /* frames/s x 1000 */
    xil_printf("FPS frames=%u inferences=%u skipped=%d time_us=%u fps_x1000=%u\r\n",
               frames, infers, (int)(frames - infers), (u32)(ticks * 1000000u / TIMER_HZ), mfps);
}

/* Classify one 28x28 image with the hardware CNN through the inject RAM. */
static u32 infer_injected(const unsigned char *img)
{
    u32 n0 = eai_rd(EAI_CNN_COUNT);
    for (int i = 0; i < EAI_ROI_PIXELS; i++) eai_wr(EAI_INJECT_DATA + 4u * (u32)i, img[i]);
    eai_wr(EAI_CNN_START, 1u);
    while (eai_rd(EAI_CNN_COUNT) == n0) { }
    return eai_rd(EAI_RESULT);
}

static void inject_selftest(void)
{
    u32 ctrl = eai_rd(EAI_CTRL);
    int exact = 0, correct = 0;

    eai_wr(EAI_CTRL, ctrl | EAI_CTRL_INJECT);          /* auto mode is off while injecting */
    while (EAI_RESULT_BUSY(eai_rd(EAI_RESULT))) { }
    for (int k = 0; k < MNIST_N_TEST; k++) {
        u32 r = infer_injected(mnist_img[k]);
        int ok = (EAI_RESULT_DIGIT(r) == mnist_golden_digit[k]) && (EAI_RESULT_CONF(r) == mnist_golden_conf[k]);
        exact += ok;
        correct += (EAI_RESULT_DIGIT(r) == mnist_label[k]);
        xil_printf("  img %2d: label %u  hw digit %u conf %3u  golden %u/%3u  %s\r\n", k, mnist_label[k],
                   EAI_RESULT_DIGIT(r), EAI_RESULT_CONF(r), mnist_golden_digit[k], mnist_golden_conf[k],
                   ok ? "bit-exact" : "MISMATCH");
    }
    eai_wr(EAI_CTRL, ctrl);
    xil_printf("INJECT %d/%d bit-exact vs golden model, %d/%d correct vs labels, latency %u cycles\r\n",
               exact, MNIST_N_TEST, correct, MNIST_N_TEST, eai_rd(EAI_CNN_CYCLES));
}

static void move_roi(int dx, int dy)
{
    u32 roi = eai_rd(EAI_ROI_POS);
    int x = (int)(roi & 0x7FFu) + dx, y = (int)((roi >> 16) & 0x7FFu) + dy;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > 1280 - 224) x = 1280 - 224;
    if (y > 720 - 224)  y = 720 - 224;
    eai_wr(EAI_ROI_POS, ((u32)y << 16) | (u32)x);
}

static void help(void)
{
    xil_printf("commands: p=prediction s=status j=inject self-test c=capture f=fps test w/a/z/d=move box x=center "
               "i=invert t=threshold +/-=threshold h=help\r\n");
}

int main(void)
{
    xil_printf("\r\n=== fpga-edge-ai-video: Phase 6 live demo ===\r\n");
    if (eai_rd(EAI_ID) != EAI_ID_VALUE)
        xil_printf("ERR wrong ID 0x%08x (bitstream not loaded?)\r\n", eai_rd(EAI_ID));
    eai_wr(EAI_CTRL, eai_rd(EAI_CTRL) | EAI_CTRL_CNN_ENABLE);
    print_status();
    help();

    u32 last_digit = 0xFF;
    while (1) {
        /* live: report when the predicted digit changes */
        u32 r = eai_rd(EAI_RESULT);
        if (EAI_RESULT_VALID(r) && EAI_RESULT_DIGIT(r) != last_digit) {
            last_digit = EAI_RESULT_DIGIT(r);
            print_prediction();
        }
        if (!key_available()) { usleep(20000); continue; }

        u32 ctrl = eai_rd(EAI_CTRL), thr = eai_rd(EAI_THRESH);
        switch (key_read()) {
            case 'p': print_prediction(); break;
            case 's': print_status(); break;
            case 'j': inject_selftest(); break;
            case 'c': capture(); break;
            case 'f': fps_test(); break;
            case 'w': move_roi(0, -ROI_STEP); print_status(); break;
            case 'a': move_roi(-ROI_STEP, 0); print_status(); break;
            case 'z': move_roi(0, ROI_STEP);  print_status(); break;
            case 'd': move_roi(ROI_STEP, 0);  print_status(); break;
            case 'x': eai_wr(EAI_ROI_POS, (ROI_Y_CENTER << 16) | ROI_X_CENTER); print_status(); break;
            case 'i': eai_wr(EAI_CTRL, ctrl ^ EAI_CTRL_INVERT);    print_status(); break;
            case 't': eai_wr(EAI_CTRL, ctrl ^ EAI_CTRL_THRESH_EN); print_status(); break;
            case '+': eai_wr(EAI_THRESH, thr <= 247 ? thr + 8 : 255); print_status(); break;
            case '-': eai_wr(EAI_THRESH, thr >= 8 ? thr - 8 : 0);     print_status(); break;
            case 'h': help(); break;
            default: break;
        }
    }
    return 0;
}
