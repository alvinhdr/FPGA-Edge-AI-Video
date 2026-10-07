/* =============================================================================
 * File   : main.c
 * Project: Real-Time Edge AI Video Processor on FPGA
 * Purpose: Phase 4 ARM program. Talks to the PC over the USB-UART (115200 8N1)
 *          and controls the ROI capture hardware through AXI-Lite.
 *
 * Commands (one character from the PC, e.g. from scripts/capture_roi.py or PuTTY):
 *   c : capture  -> prints "ROI <1568 hex chars>" (28x28 bytes, row-major)
 *   i : toggle invert          t : toggle threshold
 *   + : threshold + 8          - : threshold - 8
 *   s : print status           h : help
 *
 * Capture procedure (why the steps are needed):
 *   1. wait for 2 new completed frames  -> the ready bank holds a fresh image
 *   2. set FREEZE, wait 50 ms (3 frames) -> the hardware stops flipping banks,
 *                                           so the ready bank cannot change
 *   3. read the 784 bytes through AXI-Lite, check the bank did not change
 *   4. clear FREEZE
 * ========================================================================== */
#include "xil_printf.h"
#include "sleep.h"
#include "edge_ai_regs.h"

extern char inbyte(void);          /* blocking UART read, from the standalone BSP */
extern void outbyte(char c);

static void put_hex_byte(u8 v)
{
    static const char hex[] = "0123456789abcdef";
    outbyte(hex[v >> 4]);
    outbyte(hex[v & 0xF]);
}

static void print_status(void)
{
    u32 ctrl = eai_rd(EAI_CTRL);
    u32 roi  = eai_rd(EAI_ROI_POS);
    xil_printf("STATUS id=0x%08x frames=%u bank=%u invert=%u thresh_en=%u thresh=%u roi=(%u,%u)\r\n",
               eai_rd(EAI_ID), eai_rd(EAI_FRAME_CNT), eai_rd(EAI_STATUS) & 1u,
               (ctrl & EAI_CTRL_INVERT) ? 1 : 0, (ctrl & EAI_CTRL_THRESH_EN) ? 1 : 0,
               eai_rd(EAI_THRESH), roi & 0x7FFu, (roi >> 16) & 0x7FFu);
}

/* Wait until the frame counter has advanced by n. Returns 0 on timeout (no video). */
static int wait_frames(u32 n)
{
    u32 start = eai_rd(EAI_FRAME_CNT);
    for (int ms = 0; ms < 500; ms++) {
        if (eai_rd(EAI_FRAME_CNT) - start >= n) return 1;
        usleep(1000);
    }
    return 0;
}

static void capture(void)
{
    static u8 buf[EAI_ROI_PIXELS];
    u32 ctrl = eai_rd(EAI_CTRL);

    if (!wait_frames(2)) {
        xil_printf("ERR no frames (is HDMI video at 1280x720 coming in?)\r\n");
        return;
    }
    eai_wr(EAI_CTRL, ctrl | EAI_CTRL_FREEZE);
    usleep(50000);

    for (int attempt = 0; attempt < 3; attempt++) {
        u32 bank_before = eai_rd(EAI_STATUS) & 1u;
        for (int i = 0; i < EAI_ROI_PIXELS; i++) buf[i] = (u8)eai_rd(EAI_ROI_DATA + 4u * (u32)i);
        if ((eai_rd(EAI_STATUS) & 1u) == bank_before) break;   /* stable: done */
    }
    eai_wr(EAI_CTRL, ctrl & ~EAI_CTRL_FREEZE);

    xil_printf("ROI ");
    for (int i = 0; i < EAI_ROI_PIXELS; i++) put_hex_byte(buf[i]);
    xil_printf("\r\n");
}

int main(void)
{
    xil_printf("\r\n=== fpga-edge-ai-video: Phase 4 ROI capture ===\r\n");
    if (eai_rd(EAI_ID) != EAI_ID_VALUE) {
        xil_printf("ERR wrong ID 0x%08x (bitstream not loaded?)\r\n", eai_rd(EAI_ID));
    }
    print_status();
    xil_printf("commands: c=capture i=invert t=threshold +/-=threshold s=status h=help\r\n");

    while (1) {
        char cmd = inbyte();
        u32 ctrl = eai_rd(EAI_CTRL);
        u32 thr  = eai_rd(EAI_THRESH);
        switch (cmd) {
            case 'c': capture(); break;
            case 'i': eai_wr(EAI_CTRL, ctrl ^ EAI_CTRL_INVERT);    print_status(); break;
            case 't': eai_wr(EAI_CTRL, ctrl ^ EAI_CTRL_THRESH_EN); print_status(); break;
            case '+': eai_wr(EAI_THRESH, thr <= 247 ? thr + 8 : 255); print_status(); break;
            case '-': eai_wr(EAI_THRESH, thr >= 8 ? thr - 8 : 0);     print_status(); break;
            case 's': print_status(); break;
            case 'h': xil_printf("commands: c i t + - s h\r\n"); break;
            default: break;   /* ignore CR/LF and unknown keys */
        }
    }
    return 0;
}
