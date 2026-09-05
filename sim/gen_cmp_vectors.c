/* gen_cmp_vectors.c —— fp32_cmp 的 IEEE(FTZ) 金标准向量（[#37] V1-D §3.1）
 *
 * 金标准对 C float 这个与设计无关的第三方（SOP §2），不与自己比。
 * 语义契约（与 fp32_add/fp32_mul_pipe 的 FTZ 真身一致）：
 *   · denormal 输入按 ±0 参与比较（否则会出现 "fcmp 说非零、乘加当零" 的自相矛盾）
 *   · ±0 相等
 *   · 任一 NaN ⇒ unordered ⇒ 返回值由调用家族决定（libgcc __*sf2 ABI）：
 *       gt_family=0（lt/le/eq/ne）→ +1   ⇒ `<0` `<=0` `==0` 均为假、`!=0` 为真
 *       gt_family=1（gt/ge）      → -1   ⇒ `>0` `>=0` 均为假
 *
 * 输出格式（每行）：a b gt_family expected   —— 全 %08x
 *
 * 用法：
 *   gcc -O2 -ffp-contract=off -o gen_cmp gen_cmp_vectors.c && ./gen_cmp 200000 37
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

static uint32_t f2b(float f){ uint32_t u; memcpy(&u,&f,4); return u; }
static float    b2f(uint32_t u){ float f; memcpy(&f,&u,4); return f; }

/* FTZ: exp==0（含 denormal 与 ±0）一律归 ±0，保符号 */
static uint32_t ftz_bits(uint32_t u){
    return ((u & 0x7F800000u) == 0u) ? (u & 0x80000000u) : u;
}

/* 三态码金标准；unordered 由调用方按家族给值 */
static int32_t ref_cmp(uint32_t ua, uint32_t ub, int gt_family){
    float a = b2f(ftz_bits(ua));
    float b = b2f(ftz_bits(ub));
    if (isnan(a) || isnan(b)) return gt_family ? -1 : 1;
    if (a < b) return -1;
    if (a == b) return 0;      /* +0 == -0 由 C 语义天然成立 */
    return 1;
}

/* 随机 FP32：全指数域均匀，含 denormal(exp=0)/Inf/NaN(exp=255) */
static uint32_t rand_bits(unsigned *seed){
    uint32_t sign = (uint32_t)(rand_r(seed) & 1) << 31;
    uint32_t exp  = (uint32_t)(rand_r(seed) % 256) & 0xFF;
    uint32_t frac = (uint32_t)rand_r(seed) & 0x7FFFFF;
    return sign | (exp << 23) | frac;
}

int main(int argc, char **argv){
    int N         = (argc > 1) ? atoi(argv[1]) : 200000;
    unsigned seed = (argc > 2) ? (unsigned)atoi(argv[2]) : 37u;
    const char *fn = "vectors_cmp.txt";
    FILE *fp = fopen(fn, "w");
    if (!fp) { fprintf(stderr, "ERR open %s\n", fn); return 1; }

    /* ① 边界值全配对 —— 比较器的错都在这里，不能只靠随机撞 */
    static const uint32_t edge[] = {
        0x00000000u, 0x80000000u,             /* ±0 */
        0x00000001u, 0x80000001u,             /* ±dmin  (FTZ→±0) */
        0x007FFFFFu, 0x807FFFFFu,             /* ±dmax  (FTZ→±0) */
        0x00800000u, 0x80800000u,             /* ±最小规格化数 */
        0x3F800000u, 0xBF800000u,             /* ±1.0 */
        0x40000000u, 0xC0000000u,             /* ±2.0 */
        0x7F7FFFFFu, 0xFF7FFFFFu,             /* ±max finite */
        0x7F800000u, 0xFF800000u,             /* ±Inf */
        0x7FC00000u, 0xFFC00000u,             /* ±qNaN */
        0x7F800001u, 0xFF800001u,             /* ±sNaN */
    };
    const int NE = (int)(sizeof(edge)/sizeof(edge[0]));
    int n_edge = 0;
    for (int i = 0; i < NE; i++)
        for (int j = 0; j < NE; j++)
            for (int gf = 0; gf < 2; gf++){
                fprintf(fp, "%08x %08x %08x %08x\n", edge[i], edge[j],
                        (uint32_t)gf, (uint32_t)ref_cmp(edge[i], edge[j], gf));
                n_edge++;
            }

    /* ② 随机 + ③ 邻近值（同指数、尾数只差 1-2 ULP，逼绝对值比较的边界） */
    for (int i = 0; i < N; i++){
        uint32_t a, b;
        int gf = rand_r(&seed) & 1;
        if (i % 4 == 3){
            a = rand_bits(&seed);
            int d = (int)(rand_r(&seed) % 5) - 2;      /* -2..+2 */
            b = (uint32_t)((int64_t)a + d);
        } else {
            a = rand_bits(&seed);
            b = rand_bits(&seed);
        }
        fprintf(fp, "%08x %08x %08x %08x\n", a, b,
                (uint32_t)gf, (uint32_t)ref_cmp(a, b, gf));
    }
    fclose(fp);
    printf("wrote %d vectors to %s (edge=%d random=%d seed=%u)\n",
           n_edge + N, fn, n_edge, N, seed);
    return 0;
}
