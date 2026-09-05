/* gen_recip_vectors.c —— fp32_recip 的 IEEE 金标准向量（[#37] V1-D §3.3）
 *
 * 金标准对 C float 1/x 这个与设计无关的第三方（SOP §2），不与自己比。
 * FTZ契约：denormal→±0→±Inf。
 *
 * 输出格式（每行）：a expected   —— 全 %08x
 *
 * 用法：
 *   gcc -O2 -ffp-contract=off -o gen_recip gen_recip_vectors.c && ./gen_recip 200000 37
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

static uint32_t f2b(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    b2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }

/* FTZ: exp==0 → ±0 */
static float ftz_float(float x){
    uint32_t u = f2b(x);
    if ((u & 0x7F800000u) == 0u) return (u & 0x80000000u) ? -0.0f : 0.0f;
    return x;
}

static uint32_t ftz_bits(uint32_t u){
    return ((u & 0x7F800000u) == 0u) ? (u & 0x80000000u) : u;
}

static uint32_t ref_recip(uint32_t ua){
    float a = ftz_float(b2f(ua));
    float r;
    if (isnan(a))           r = a;                // NaN → NaN
    else if (isinf(a))      r = (a > 0) ? 0.0f : -0.0f;  // ±Inf → ±0
    else if (a == 0.0f)     r = copysignf(INFINITY, a);   // ±0 → ±Inf
    else if (a == -0.0f)    r = -INFINITY;
    else                    r = 1.0f / a;
    return ftz_bits(f2b(r));  // FTZ output: denormal→±0
}

static uint32_t rand_bits(unsigned *seed){
    uint32_t sign = (uint32_t)(rand_r(seed) & 1) << 31;
    uint32_t exp  = (uint32_t)(rand_r(seed) % 255) & 0xFF;   // 0..254, 避免NaN/Inf
    uint32_t frac = (uint32_t)rand_r(seed) & 0x7FFFFF;
    return sign | (exp << 23) | frac;
}

int main(int argc, char **argv){
    int N         = (argc > 1) ? atoi(argv[1]) : 200000;
    unsigned seed = (argc > 2) ? (unsigned)atoi(argv[2]) : 37u;
    const char *fn = "vectors_recip.txt";
    FILE *fp = fopen(fn, "w");
    if (!fp) { fprintf(stderr, "ERR open %s\n", fn); return 1; }

    /* ① 边界值 */
    static const uint32_t edge[] = {
        0x00000000u, 0x80000000u,             /* ±0 */
        0x3F800000u, 0xBF800000u,             /* ±1.0 */
        0x40000000u, 0xC0000000u,             /* ±2.0 */
        0x3F000000u,                           /* 0.5 */
        0x40400000u,                           /* 3.0 */
        0x3F333333u,                           /* 0.7 */
        0x40800000u,                           /* 4.0 */
        0x7F800000u, 0xFF800000u,             /* ±Inf */
        0x7FC00000u,                           /* qNaN */
        0x00000001u, 0x80000001u,             /* ±dmin (FTZ→0→±Inf) */
        0x007FFFFFu, 0x807FFFFFu,             /* ±dmax (FTZ→0→±Inf) */
        0x00800000u, 0x80800000u,             /* ±最小规格化数 */
        0x7F7FFFFFu, 0xFF7FFFFFu,             /* ±max finite */
    };
    int NE = (int)(sizeof(edge)/sizeof(edge[0]));
    for (int i = 0; i < NE; i++){
        fprintf(fp, "%08x %08x\n", edge[i], ref_recip(edge[i]));
    }

    /* ② 随机 */
    for (int i = 0; i < N; i++){
        uint32_t a = rand_bits(&seed);
        fprintf(fp, "%08x %08x\n", a, ref_recip(a));
    }
    fclose(fp);
    printf("wrote %d vectors to %s (edge=%d random=%d seed=%u)\n",
           NE + N, fn, NE, N, seed);
    return 0;
}
