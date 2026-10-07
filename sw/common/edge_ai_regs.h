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

#define EAI_ID            0x0000u   /* RO  0xED6E0004                                   */
#define EAI_CTRL          0x0004u   /* RW  [0] invert [1] thresh_en [2] freeze          */
#define EAI_THRESH        0x0008u   /* RW  [7:0] threshold                              */
#define EAI_ROI_POS       0x000Cu   /* RW  [10:0] x0  [26:16] y0                        */
#define EAI_STATUS        0x0010u   /* RO  [0] ready bank                               */
#define EAI_FRAME_CNT     0x0014u   /* RO  completed ROI captures                       */
#define EAI_ROI_DATA      0x1000u   /* RO  pixel i at EAI_ROI_DATA + 4*i, i = 0..783    */

#define EAI_CTRL_INVERT    (1u << 0)
#define EAI_CTRL_THRESH_EN (1u << 1)
#define EAI_CTRL_FREEZE    (1u << 2)

#define EAI_ID_VALUE      0xED6E0004u
#define EAI_ROI_GRID      28
#define EAI_ROI_PIXELS    (EAI_ROI_GRID * EAI_ROI_GRID)

static inline u32  eai_rd(u32 off)          { return Xil_In32(EAI_BASE + off); }
static inline void eai_wr(u32 off, u32 val) { Xil_Out32(EAI_BASE + off, val); }

#endif
