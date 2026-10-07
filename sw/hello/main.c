/* =============================================================================
 * File   : main.c
 * Project: Real-Time Edge AI Video Processor on FPGA
 * Purpose: Phase 1 bare-metal test for the ARM Cortex-A9 (PS).
 *          Prints "hello" over the USB-UART (UART1, 115200 baud) once per second,
 *          so we know the ARM, the UART and the PuTTY setup all work.
 * ========================================================================== */
#include <stdio.h>
#include "xil_printf.h"
#include "sleep.h"

int main(void)
{
    unsigned int count = 0;

    xil_printf("\r\n=== fpga-edge-ai-video: Phase 1 ===\r\n");
    xil_printf("hello from the ARM Cortex-A9 on the Zybo Z7-10\r\n");

    while (1) {
        xil_printf("alive %u\r\n", count++);
        sleep(1);
    }

    return 0;
}
