/* =============================================================================
 * File   : main.c
 * Project: Real-Time Edge AI Video Processor on FPGA
 * Purpose: Phase 7 benchmark. The PC (scripts/bench_mnist.py) sends MNIST test images
 *          over the UART; for each image this program
 *            1. runs the HARDWARE CNN through the inject RAM (timed), and
 *            2. runs the SOFTWARE CNN on the ARM (sw/common/cnn_ref.h, timed),
 *          and sends one result line back. The PC compares everything with the
 *          Python golden model and the true labels.
 *
 * Protocol (115200 8N1):
 *   at start : "BENCH READY freq=<timer Hz> optimized=<0|1>" (again on byte 'H')
 *   PC -> ARM: byte 'I' then 784 image bytes (row by row)
 *   ARM -> PC: "R <hw digit> <hw conf> <sw digit> <sw conf> <acc match 0|1> <hw cycles>
 *               <hw ticks> <sw ticks> <acc0> ... <acc9>"
 *   ticks    : ARM global timer ticks (frequency printed at start)
 *   hw ticks : inject 784 pixels + start + wait + read result (what the ARM sees)
 *   hw cycles: clk_acc cycles the CNN itself needs (hardware counter)
 *   sw ticks : cnn_ref_infer() only
 * ========================================================================== */
#include "xil_printf.h"
#include "xparameters.h"
#include "xuartps_hw.h"
#include "xiltimer.h"
#include "sleep.h"
#include "edge_ai_regs.h"
#include "cnn_ref.h"

/* Cortex-A9 global timer = CPU clock / 2 (Zynq-7000 TRM); XTime_GetTime() reads it. */
#define TIMER_HZ  ((u32)(XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2))

static unsigned char img[EAI_ROI_PIXELS];

static unsigned char rx(void) { return (unsigned char)XUartPs_RecvByte(STDIN_BASEADDRESS); }

int main(void)
{
    cnn_ref_result_t sw;
    int opt = 0;
#ifdef __OPTIMIZE__
    opt = 1;
#endif
    if (eai_rd(EAI_ID) != EAI_ID_VALUE)
        xil_printf("ERR wrong ID 0x%08x (bitstream not loaded?)\r\n", eai_rd(EAI_ID));
    /* inject mode: the CNN only runs when the ARM starts it; keep it enabled */
    eai_wr(EAI_CTRL, (eai_rd(EAI_CTRL) | EAI_CTRL_CNN_ENABLE | EAI_CTRL_INJECT));
    while (EAI_RESULT_BUSY(eai_rd(EAI_RESULT))) { }
    /* The BSP (xiltimer) starts the global timer only on the first sleep call;
     * without this, XTime_GetTime() always returns 0. */
    usleep(10);
    xil_printf("BENCH READY freq=%u optimized=%d\r\n", TIMER_HZ, opt);

    while (1) {
        unsigned char cmd = rx();
        if (cmd == 'H') { xil_printf("BENCH READY freq=%u optimized=%d\r\n", TIMER_HZ, opt); continue; }
        if (cmd != 'I') continue;
        for (int i = 0; i < EAI_ROI_PIXELS; i++) img[i] = rx();

        XTime t0, t1, t2, t3;
        u32 n0 = eai_rd(EAI_CNN_COUNT);
        XTime_GetTime(&t0);
        for (int i = 0; i < EAI_ROI_PIXELS; i++) eai_wr(EAI_INJECT_DATA + 4u * (u32)i, img[i]);
        eai_wr(EAI_CNN_START, 1u);
        while (eai_rd(EAI_CNN_COUNT) == n0) { }
        u32 res = eai_rd(EAI_RESULT);
        XTime_GetTime(&t1);
        u32 cyc = eai_rd(EAI_CNN_CYCLES);
        int hwacc[10];
        for (int k = 0; k < 10; k++) hwacc[k] = (int)eai_rd(EAI_FC_ACC + 4u * (u32)k);

        XTime_GetTime(&t2);
        cnn_ref_infer(img, &sw);
        XTime_GetTime(&t3);

        int match = 1;
        for (int k = 0; k < 10; k++) if (hwacc[k] != sw.acc[k]) match = 0;

        xil_printf("R %u %u %u %u %d %u %u %u", EAI_RESULT_DIGIT(res), EAI_RESULT_CONF(res),
                   sw.digit, sw.conf, match, cyc, (u32)(t1 - t0), (u32)(t3 - t2));
        for (int k = 0; k < 10; k++) xil_printf(" %d", hwacc[k]);
        xil_printf("\r\n");
    }
    return 0;
}
