/* =============================================================================
 * File   : cnn_ref.h
 * Project: Real-Time Edge AI Video Processor on FPGA
 * Purpose: Software (C) version of the CNN: the SAME integer math as
 *          ml/golden_int.py and the hardware (docs/QUANTIZATION.md). Used as the
 *          ARM Cortex-A9 baseline in Phase 7 (speedup = ARM time / FPGA time).
 *          Written plainly (simple loops, int64 for the requantization multiply),
 *          not hand-tuned, so the comparison stays honest and easy to explain.
 * Header-only: include it from ONE .c file of an application.
 * ========================================================================== */
#ifndef CNN_REF_H
#define CNN_REF_H

#include "cnn_weights.h"

typedef struct {
    int           acc[10];   /* FC accumulators                         */
    unsigned char digit;     /* argmax (ties -> smallest index)         */
    unsigned char conf;      /* 0..255                                  */
} cnn_ref_result_t;

static inline unsigned char cnn_ref_requant(int acc, int m, int s)
{
    long long v = ((long long)acc * m + (1LL << (s - 1))) >> s;   /* arithmetic shift */
    return (unsigned char)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

static unsigned char cnn_l1[8][26][26], cnn_p1[8][13][13], cnn_l2[16][11][11], cnn_p2[16][5][5];

static void cnn_ref_infer(const unsigned char *img /* 28*28 */, cnn_ref_result_t *r)
{
    /* L1: conv 3x3, 1 -> 8 channels */
    for (int o = 0; o < 8; o++)
        for (int y = 0; y < 26; y++)
            for (int x = 0; x < 26; x++) {
                int acc = cnn_b1[o];
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++)
                        acc += img[(y + ky) * 28 + x + kx] * cnn_w1[o * 9 + ky * 3 + kx];
                cnn_l1[o][y][x] = cnn_ref_requant(acc, CNN_M1, CNN_S1);
            }
    /* P1: max-pool 2x2 */
    for (int c = 0; c < 8; c++)
        for (int y = 0; y < 13; y++)
            for (int x = 0; x < 13; x++) {
                unsigned char a = cnn_l1[c][2 * y][2 * x], b = cnn_l1[c][2 * y][2 * x + 1];
                unsigned char d = cnn_l1[c][2 * y + 1][2 * x], e = cnn_l1[c][2 * y + 1][2 * x + 1];
                unsigned char m = a > b ? a : b;
                if (d > m) m = d;
                if (e > m) m = e;
                cnn_p1[c][y][x] = m;
            }
    /* L2: conv 3x3, 8 -> 16 channels */
    for (int o = 0; o < 16; o++)
        for (int y = 0; y < 11; y++)
            for (int x = 0; x < 11; x++) {
                int acc = cnn_b2[o];
                for (int c = 0; c < 8; c++)
                    for (int ky = 0; ky < 3; ky++)
                        for (int kx = 0; kx < 3; kx++)
                            acc += cnn_p1[c][y + ky][x + kx] * cnn_w2[o * 72 + c * 9 + ky * 3 + kx];
                cnn_l2[o][y][x] = cnn_ref_requant(acc, CNN_M2, CNN_S2);
            }
    /* P2: max-pool 2x2 (11 -> 5, last row/column dropped) */
    for (int c = 0; c < 16; c++)
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 5; x++) {
                unsigned char a = cnn_l2[c][2 * y][2 * x], b = cnn_l2[c][2 * y][2 * x + 1];
                unsigned char d = cnn_l2[c][2 * y + 1][2 * x], e = cnn_l2[c][2 * y + 1][2 * x + 1];
                unsigned char m = a > b ? a : b;
                if (d > m) m = d;
                if (e > m) m = e;
                cnn_p2[c][y][x] = m;
            }
    /* FC 400 -> 10 (input index = c*25 + y*5 + x), no ReLU */
    const unsigned char *flat = &cnn_p2[0][0][0];
    for (int o = 0; o < 10; o++) {
        int acc = cnn_bf[o];
        for (int i = 0; i < 400; i++) acc += flat[i] * cnn_wf[o * 400 + i];
        r->acc[o] = acc;
    }
    /* argmax (strict >, so ties keep the smallest index) and confidence */
    int best = 0;
    for (int o = 1; o < 10; o++) if (r->acc[o] > r->acc[best]) best = o;
    int second = -2147483647 - 1;
    for (int o = 0; o < 10; o++) if (o != best && r->acc[o] > second) second = r->acc[o];
    long long diff = (long long)r->acc[best] - second;
    long long c = (diff * CNN_MC + (1LL << (CNN_SC - 1))) >> CNN_SC;
    r->digit = (unsigned char)best;
    r->conf  = (unsigned char)(c > 255 ? 255 : c);
}

#endif
