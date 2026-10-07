/* =============================================================================
 * File   : edge_ai_regs.h
 * Project: Real-Time Edge AI Video Processor on FPGA
 * Purpose: Register map of rtl/axil_regs.sv for the ARM software.
 *          Base address = AXIL_BASE in scripts/build_hw.tcl (block design).
 * ========================================================================== */
#ifndef EDGE_AI_REGS_H
#define EDGE_AI_REGS_H

#include "xil_io.h"

#define EAI_BASE          0x43C00000u

#define EAI_ID            0x0000u   /* RO  0xED6E0006                                         */
#define EAI_CTRL          0x0004u   /* RW  [0] invert [1] thresh_en [2] freeze [3] cnn_enable [4] inject_mode */
#define EAI_THRESH        0x0008u   /* RW  [7:0] threshold                                    */
#define EAI_ROI_POS       0x000Cu   /* RW  [10:0] x0  [26:16] y0                              */
#define EAI_STATUS        0x0010u   /* RO  [0] ready bank                                     */
#define EAI_FRAME_CNT     0x0014u   /* RO  completed ROI captures                             */
#define EAI_CNN_START     0x0018u   /* WO  bit 0 = 1: run the CNN once                        */
#define EAI_RESULT        0x001Cu   /* RO  [3:0] digit [15:8] conf [16] valid [31] busy       */
#define EAI_CNN_CYCLES    0x0020u   /* RO  clocks of the last inference                       */
#define EAI_CNN_COUNT     0x0024u   /* RO  finished inferences                                */
#define EAI_FC_ACC        0x0040u   /* RO  FC accumulator k at EAI_FC_ACC + 4*k, k = 0..9     */
#define EAI_ROI_DATA      0x1000u   /* RO  ROI pixel i at EAI_ROI_DATA + 4*i, i = 0..783      */
#define EAI_INJECT_DATA   0x2000u   /* WO  inject RAM pixel i at EAI_INJECT_DATA + 4*i        */

#define EAI_CTRL_INVERT      (1u << 0)
#define EAI_CTRL_THRESH_EN   (1u << 1)
#define EAI_CTRL_FREEZE      (1u << 2)
#define EAI_CTRL_CNN_ENABLE  (1u << 3)
#define EAI_CTRL_INJECT      (1u << 4)

#define EAI_RESULT_DIGIT(r)  ((r) & 0xFu)
#define EAI_RESULT_CONF(r)   (((r) >> 8) & 0xFFu)
#define EAI_RESULT_VALID(r)  (((r) >> 16) & 1u)
#define EAI_RESULT_BUSY(r)   (((r) >> 31) & 1u)

#define EAI_ID_VALUE      0xED6E0006u
#define EAI_ROI_GRID      28
#define EAI_ROI_PIXELS    (EAI_ROI_GRID * EAI_ROI_GRID)
#define EAI_CLK_MHZ       100u      /* clk_acc */

static inline u32  eai_rd(u32 off)          { return Xil_In32(EAI_BASE + off); }
static inline void eai_wr(u32 off, u32 val) { Xil_Out32(EAI_BASE + off, val); }

#endif
