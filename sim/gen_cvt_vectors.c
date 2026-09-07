/* gen_cvt_vectors.c —— fp32_cvt 的 IEEE 金标准向量
 *
 * 金标准对 C float/int 这个与设计无关的第三方，不与自己比。
 * 输出格式（每行）：in mode unsigned expected   —— 全 %08x
 *   mode: 0=i2f, 1=f2i
 *
 * 用法：
 *   gcc -O2 -ffp-contract=off -o gen_cvt gen_cvt_vectors.c && ./gen_cvt 100000 37
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

static uint32_t f2b(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    b2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }

/* FTZ: exp==0 → ±0 */
static uint32_t ftz_bits(uint32_t u){
    return ((u & 0x7F800000u) == 0u) ? (u & 0x80000000u) : u;
}

/* i2f 金标准：用 C 的 (float) 强制转换 */
static uint32_t ref_i2f(uint32_t in, int is_unsigned){
    if (is_unsigned) return f2b((float)(*(unsigned*)&in));
    else             return f2b((float)(*(int*)&in));
}

/* f2i 金标准：FTZ 后截断向零 */
static uint32_t ref_f2i(uint32_t in, int is_unsigned){
    uint32_t f = ftz_bits(in);
    float val = b2f(f);
    if (isnan((float)val)){
        // 与 libgcc 对齐：NaN → 0
        return 0;
    }
    if (is_unsigned){
        if (val <= 0.0f)           return 0;
        if (val >= 4294967296.0f)  return 0xFFFFFFFFu;
        return (uint32_t)(unsigned long long)val;
    } else {
        if (val <= -2147483648.0f) return 0x80000000u;
        if (val >=  2147483648.0f) return 0x7FFFFFFFu;
        return (uint32_t)(int)val;
    }
}

/* rand_r 只返回 0..2^31-1 ⇒ 直接用它做 32 位激励，**bit31 恒为 0**：
 *   i2f 永远测不到负整数、f2i 永远测不到负浮点与 unsigned 的钳位路径。
 *   （改前实测：5 万条随机向量里 bit31=1 的只有 2 条，全靠定向用例撑着。）
 *   拼两次取满 32 位。 */
static uint32_t rand_bits(unsigned *seed){
    uint32_t lo = (uint32_t)rand_r(seed) & 0xFFFFu;
    uint32_t hi = (uint32_t)rand_r(seed) & 0xFFFFu;
    return (hi << 16) | lo;
}

int main(int argc, char **argv){
    int N         = (argc > 1) ? atoi(argv[1]) : 100000;
    unsigned seed = (argc > 2) ? (unsigned)atoi(argv[2]) : 37u;
    const char *fn = "vectors_cvt.txt";
    FILE *fp = fopen(fn, "w");
    if (!fp) { fprintf(stderr, "ERR open %s\n", fn); return 1; }

    /* ① i2f 边界值 */
    static const uint32_t i2f_edges[] = {
        0x00000000u, 0x00000001u, 0x00000002u,
        0x0000007Fu, 0x00000080u, 0x000000FFu,
        0x00007FFFu, 0x00008000u, 0x0000FFFFu,
        0x007FFFFFu, 0x00800000u, 0x3FFFFFFFu,
        0x40000000u, 0x7FFFFFFFu,
    };
    int NE = (int)(sizeof(i2f_edges)/sizeof(i2f_edges[0]));
    int n_total = 0;
    // signed i2f
    for (int i = 0; i < NE; i++){
        uint32_t exp = ref_i2f(i2f_edges[i], 0);
        fprintf(fp, "%08x 0 0 %08x\n", i2f_edges[i], exp);
        n_total++;
    }
    // unsigned i2f
    for (int i = 0; i < NE; i++){
        uint32_t exp = ref_i2f(i2f_edges[i], 1);
        fprintf(fp, "%08x 0 1 %08x\n", i2f_edges[i], exp);
        n_total++;
    }
    // negative signed i2f
    uint32_t neg_edges[] = {0x80000000u, 0x80000001u, 0x8000FFFFu, 0x80FFFFFFu, 0xFFFFFFFFu};
    int NN = (int)(sizeof(neg_edges)/sizeof(neg_edges[0]));
    for (int i = 0; i < NN; i++){
        uint32_t exp = ref_i2f(neg_edges[i], 0);
        fprintf(fp, "%08x 0 0 %08x\n", neg_edges[i], exp);
        n_total++;
    }

    /* ② f2i 边界值 */
    static const uint32_t f2i_edges[] = {
        0x00000000u, 0x80000000u,             /* ±0 */
        0x00000001u, 0x80000001u,             /* ±dmin (FTZ→0) */
        0x3F000000u,                           /* 0.5 → 0 */
        0x3F800000u, 0xBF800000u,             /* ±1.0 */
        0x40000000u, 0xC0000000u,             /* ±2.0 */
        0x4EFFFFFFu,                           /* ~2^30 */
        0x4F000000u, 0xCF000000u,             /* ±2^31 */
        0x7F7FFFFFu, 0xFF7FFFFFu,             /* ±max finite */
        0x7F800000u, 0xFF800000u,             /* ±Inf */
        0x7FC00000u,                           /* qNaN */
    };
    int NF = (int)(sizeof(f2i_edges)/sizeof(f2i_edges[0]));
    // signed f2i
    for (int i = 0; i < NF; i++){
        uint32_t exp = ref_f2i(f2i_edges[i], 0);
        fprintf(fp, "%08x 1 0 %08x\n", f2i_edges[i], exp);
        n_total++;
    }
    // unsigned f2i
    for (int i = 0; i < NF; i++){
        uint32_t exp = ref_f2i(f2i_edges[i], 1);
        fprintf(fp, "%08x 1 1 %08x\n", f2i_edges[i], exp);
        n_total++;
    }

    /* ③ 随机：i2f 和 f2i 各占一半 */
    for (int i = 0; i < N; i++){
        uint32_t in  = rand_bits(&seed);
        int mode = rand_r(&seed) & 1;
        int unsg = rand_r(&seed) & 1;
        uint32_t exp;
        if (mode == 0) exp = ref_i2f(in, unsg);
        else           exp = ref_f2i(in, unsg);
        fprintf(fp, "%08x %01x %01x %08x\n", in, (uint32_t)mode, (uint32_t)unsg, exp);
        n_total++;
    }
    fclose(fp);
    printf("wrote %d vectors to %s\n", n_total, fn);
    return 0;
}
