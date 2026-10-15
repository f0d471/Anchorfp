// gen_div_vectors.c —— fp32_div 的精确整数金标准向量
//
// 期望值由本文件内的整数 oracle 给出，不以宿主 float 的除法当裁决：
// 契约 FDIV(a,b) = FTZ(RNE24(DAZ(a)/DAZ(b)))，输入 DAZ、输出 FTZ、canonical qNaN。
// 宿主 float 只用于 selftest 的共同域（两输入与结果都是规格化数）交叉复核对。
//
// 定向族是构造出来的（模逆解 A·2^k ≡ (B±1)/2 mod B）：2R = B±1 这一族在随机对里
// 撞不到，实测 50 万对 0 命中；2R = B 在规格化共同域里数学上不可达，不列。
//
// 用法：
//   gcc -O2 -ffp-contract=off -o gen_div gen_div_vectors.c && ./gen_div 500000 41
//   ./gen_div selftest
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint32_t f2b(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    b2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

#define M23 0x007FFFFFu

/* 契约参考实现：DAZ 先于分类，进位先于判界，上溢清尾数，下溢在舍入后判定 */
static uint32_t fdiv_ref(uint32_t ua, uint32_t ub)
{
    uint32_t sa = ua >> 31, ea = (ua >> 23) & 0xFFu, fa = ua & M23;
    uint32_t sb = ub >> 31, eb = (ub >> 23) & 0xFFu, fb = ub & M23;
    if (ea == 0u) fa = 0u;
    if (eb == 0u) fb = 0u;

    int a_nan  = (ea == 0xFFu && fa != 0u), b_nan  = (eb == 0xFFu && fb != 0u);
    int a_inf  = (ea == 0xFFu && fa == 0u), b_inf  = (eb == 0xFFu && fb == 0u);
    int a_zero = (ea == 0u),                b_zero = (eb == 0u);
    uint32_t s = sa ^ sb;

    if (a_nan || b_nan)   return 0x7FC00000u;                  // NaN 不保留 sign/payload
    if (a_inf && b_inf)   return 0x7FC00000u;
    if (a_zero && b_zero) return 0x7FC00000u;
    if (a_inf || b_zero)  return (s << 31) | 0x7F800000u;
    if (a_zero || b_inf)  return s << 31;

    uint32_t A = 0x800000u | fa, B = 0x800000u | fb;
    int ge = (A >= B);
    uint64_t N = ((uint64_t)A) << (ge ? 23 : 24);
    int      E = (int)ea - (int)eb + (ge ? 127 : 126);
    uint32_t Q = (uint32_t)(N / B), R = (uint32_t)(N % B);

    if (2u * R > B || (2u * R == B && (Q & 1u))) Q += 1u;      // RNE：R 保持精确，不截断
    if (Q >= 0x1000000u) { Q >>= 1; E += 1; }                  // 尾数进位
    if (E >= 255) return (s << 31) | 0x7F800000u;              // 上溢清尾数
    if (E <= 0)   return s << 31;                              // FTZ
    return (s << 31) | ((uint32_t)E << 23) | (Q & M23);
}

/* 扩展欧几里得模逆，要求 m 为奇数且 gcd(a,m) = 1。中间量 < 2^47，int64 装得下 */
static uint64_t modinv(uint64_t a, uint64_t m)
{
    int64_t t = 0, nt = 1, r = (int64_t)m, nr = (int64_t)(a % m);
    while (nr != 0) {
        int64_t q = r / nr, tmp;
        tmp = t - q * nt; t = nt; nt = tmp;
        tmp = r - q * nr; r = nr; nr = tmp;
    }
    return (uint64_t)((t < 0) ? t + (int64_t)m : t);
}

/* 构造使 2R = B±1 的 A。解 A·2^k ≡ (B±1)/2 (mod B)，再取落在 [2^23,2^24)
 * 且与 k 分支自洽的那个解（A ≥ B 走 k=23，A < B 走 k=24） */
static int make_near_tie(uint32_t B, uint32_t *pa)
{
    if ((B & 1u) == 0u) return 0;
    for (int k = 23; k <= 24; k++) {
        uint64_t inv = modinv((1ull << k) % B, B);
        for (int d = -1; d <= 1; d += 2) {
            uint64_t A0 = ((((uint64_t)B + d) / 2) * inv) % B;
            for (int c = 0; c < 2; c++) {
                uint64_t A = A0 + (uint64_t)c * B;
                if (A < (1u << 23) || A >= (1u << 24)) continue;
                if ((k == 23) != (A >= B)) continue;
                *pa = (uint32_t)A;
                return 1;
            }
        }
    }
    return 0;
}

/* 把 24 位有效数装成同阶的 FP32 输入。指数取 150，结果阶码 126/127 都在正常域 */
static void pack(uint32_t A, uint32_t B, uint32_t *pa, uint32_t *pb)
{
    *pa = (150u << 23) | (A & M23);
    *pb = (150u << 23) | (B & M23);
}

static uint32_t rand_bits(unsigned *s)
{
    return ((uint32_t)rand_r(s) << 16) ^ (uint32_t)rand_r(s);
}

static uint32_t rand_normal(unsigned *s)
{
    uint32_t sign = (uint32_t)(rand_r(s) & 1u) << 31;
    uint32_t exp  = (uint32_t)(1 + rand_r(s) % 254) << 23;
    uint32_t frac = (uint32_t)rand_r(s) & M23;
    return sign | exp | frac;
}

static const struct { uint32_t a, b, e; const char *n; } ANCHOR[] = {
    { 0x3F800000u, 0x3F800000u, 0x3F800000u, "1/1"                 },
    { 0x3F800000u, 0x40000000u, 0x3F000000u, "1/2"                 },
    { 0x40000000u, 0x3F800000u, 0x40000000u, "2/1"                 },
    { 0x40400000u, 0x40000000u, 0x3FC00000u, "3/2"                 },
    { 0x3F800000u, 0x40400000u, 0x3EAAAAABu, "1/3"                 },
    { 0x40490FDBu, 0x40000000u, 0x3FC90FDBu, "pi/2"                },
    { 0x64000000u, 0x647FFFFFu, 0x3F000001u, "2R 需第 25 位"       },
    { 0x7FC00000u, 0x3F800000u, 0x7FC00000u, "qNaN/1"              },
    { 0x3F800000u, 0x7F800001u, 0x7FC00000u, "1/sNaN"              },
    { 0x00000000u, 0x80000000u, 0x7FC00000u, "+0/-0"               },
    { 0x7F800000u, 0xFF800000u, 0x7FC00000u, "+Inf/-Inf"           },
    { 0x40400000u, 0x00000000u, 0x7F800000u, "3/+0"                },
    { 0x40400000u, 0x80000000u, 0xFF800000u, "3/-0"                },
    { 0x00000000u, 0x40400000u, 0x00000000u, "+0/3"                },
    { 0x80000000u, 0x40400000u, 0x80000000u, "-0/3"                },
    { 0x00000000u, 0x7F800000u, 0x00000000u, "+0/+Inf"             },
    { 0x00000001u, 0x3F800000u, 0x00000000u, "dmin/1 (DAZ)"        },
    { 0x00800000u, 0x41800000u, 0x00000000u, "2^-126/16 (FTZ)"     },
    { 0x7F7FFFFFu, 0x00800000u, 0x7F800000u, "maxFinite/minNormal" },
};

static int selftest(void)
{
    int nf = 0;
    int na = (int)(sizeof(ANCHOR) / sizeof(ANCHOR[0]));
    for (int i = 0; i < na; i++) {
        uint32_t g = fdiv_ref(ANCHOR[i].a, ANCHOR[i].b);
        if (g != ANCHOR[i].e) {
            nf++;
            printf("  FAIL: %-20s got=%08x exp=%08x\n", ANCHOR[i].n, g, ANCHOR[i].e);
        }
    }
    printf("  anchors: %d/%d\n", na - nf, na);

    unsigned seed = 12345u;
    int same = 0, diff = 0;
    for (int i = 0; i < 200000; i++) {
        uint32_t ua = rand_normal(&seed), ub = rand_normal(&seed);
        uint32_t ur = f2b(b2f(ua) / b2f(ub));
        uint32_t k  = ur & 0x7F800000u;
        if (k == 0u || k == 0x7F800000u) continue;      // 结果出了共同域，host 不可信
        if (fdiv_ref(ua, ub) == ur) same++; else diff++;
    }
    printf("  common-domain vs host float: same=%d diff=%d\n", same, diff);

    if (nf == 0 && diff == 0) { printf("ALL PASS\n"); return 0; }
    printf("HAS FAILURES\n");
    return 1;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "selftest") == 0) return selftest();

    int      N    = (argc > 1) ? atoi(argv[1]) : 200000;
    unsigned seed = (argc > 2) ? (unsigned)atoi(argv[2]) : 41u;
    unsigned s    = seed;
    const char *fn = "vectors_div.txt";
    FILE *fp = fopen(fn, "w");
    if (!fp) { fprintf(stderr, "ERR open %s\n", fn); return 1; }

    int cnt = 0;

    /* ① 特殊值矩阵：全组合，覆盖 §3.3 的每一行与优先级 */
    static const uint32_t pool[] = {
        0x00000000u, 0x80000000u,                   /* ±0 */
        0x00000001u, 0x807FFFFFu,                   /* ±denormal 极端 */
        0x00800000u, 0x80800000u,                   /* ±最小规格化数 */
        0x7F7FFFFFu, 0xFF7FFFFFu,                   /* ±最大有限值 */
        0x7F800000u, 0xFF800000u,                   /* ±Inf */
        0x7FC00000u, 0x7F800001u, 0xFFC00000u,      /* qNaN / sNaN / 负 qNaN */
        0x3F800000u, 0xBF800000u,                   /* ±1.0 */
        0x40400000u, 0xC0400000u,                   /* ±3.0 */
        0x3F000000u, 0xBF000000u,                   /* ±0.5 */
        0x40000000u, 0xC0000000u,                   /* ±2.0 */
        0x00000002u, 0x80000002u,                   /* ±denormal(2) */
    };
    int np = (int)(sizeof(pool) / sizeof(pool[0]));
    for (int i = 0; i < np; i++) {
        for (int j = 0; j < np; j++) {
            fprintf(fp, "%08x %08x %08x\n", pool[i], pool[j], fdiv_ref(pool[i], pool[j]));
            cnt++;
        }
    }

    /* ② 归一化分支边界：A==B、A=B±1、A<B、A>B */
    static const uint32_t BA[][2] = {
        { 0x800000u, 0x800000u }, { 0x800001u, 0x800000u },
        { 0x800000u, 0x800001u }, { 0xC00000u, 0x800000u },
        { 0xFFFFFFu, 0xFFFFFFu }, { 0x800000u, 0xC00000u },
    };
    for (int i = 0; i < 6; i++) {
        uint32_t a, b; pack(BA[i][0], BA[i][1], &a, &b);
        fprintf(fp, "%08x %08x %08x\n", a, b, fdiv_ref(a, b));
        cnt++;
    }

    /* ③ R=0 精确可除：b 取 2 的幂，A/B 必整除 */
    static const uint32_t PW[] = { 0x3F800000u, 0x40000000u, 0x3F000000u, 0x40800000u, 0x00800000u };
    for (int i = 0; i < 5; i++) {
        for (uint32_t f = 0; f < 0x800000u; f += 0x100000u) {
            uint32_t a = (150u << 23) | (0x800000u | f);
            fprintf(fp, "%08x %08x %08x\n", a, PW[i], fdiv_ref(a, PW[i]));
            cnt++;
        }
    }

    /* ④ 2R = B±1 近距平局：B 取奇数、从贴近 2^24 的一端往下扫 */
    {
        int nt = 0;
        for (uint32_t B = 0xFFFFFFu; B > 0x800000u && nt < 40; B -= 2u) {
            uint32_t A;
            if (!make_near_tie(B, &A)) continue;
            uint32_t a, b; pack(A, B, &a, &b);
            fprintf(fp, "%08x %08x %08x\n", a, b, fdiv_ref(a, b));
            cnt++; nt++;
        }
    }

    /* ⑤ 上溢与下溢分界 */
    static const uint32_t OV[][2] = {
        { 0x7F7FFFFFu, 0x3F800000u },   /* maxFinite/1.0，E=254 仍有限 */
        { 0x7F7FFFFFu, 0x3F000000u },   /* maxFinite/0.5 -> +Inf */
        { 0x7F7FFFFFu, 0x00800000u },   /* maxFinite/minNormal -> +Inf */
        { 0x00800000u, 0x3F800000u },   /* minNormal/1.0，E=1 */
        { 0x00800000u, 0x40000000u },   /* minNormal/2.0，E=0 -> +0 */
        { 0x00800000u, 0x40400000u },   /* minNormal/3.0，E<0 -> +0 */
        { 0x00800000u, 0x7F7FFFFFu },   /* minNormal/maxFinite，下溢 */
        { 0x00000001u, 0x3F800000u },   /* dmin/1.0，DAZ 输入 -> +0 */
        { 0x807FFFFFu, 0x3F800000u },   /* -dmax/1.0，DAZ 输入 -> -0 */
        { 0x7FFFFFFFu, 0x3F800000u },   /* max 位图 */
        { 0xFFFFFFFFu, 0x3F800000u },   /* -max 位图 */
    };
    for (int i = 0; i < 11; i++) {
        fprintf(fp, "%08x %08x %08x\n", OV[i][0], OV[i][1], fdiv_ref(OV[i][0], OV[i][1]));
        cnt++;
    }

    /* ⑥ 符号四象限 */
    static const uint32_t SG[][2] = {
        { 0x3F800000u, 0x40000000u }, { 0xBF800000u, 0x40000000u },
        { 0x3F800000u, 0xC0000000u }, { 0xBF800000u, 0xC0000000u },
        { 0xBF800000u, 0x00000000u }, { 0x3F800000u, 0x80000000u },
        { 0x80000000u, 0x80000000u }, { 0x80000000u, 0x00000000u },
    };
    for (int i = 0; i < 8; i++) {
        fprintf(fp, "%08x %08x %08x\n", SG[i][0], SG[i][1], fdiv_ref(SG[i][0], SG[i][1]));
        cnt++;
    }

    /* ⑦ normal 随机 */
    for (int i = 0; i < N; i++) {
        uint32_t a = rand_normal(&s), b = rand_normal(&s);
        fprintf(fp, "%08x %08x %08x\n", a, b, fdiv_ref(a, b));
        cnt++;
    }

    /* ⑧ 32 位全位图随机 */
    for (int i = 0; i < N; i++) {
        uint32_t a = rand_bits(&s), b = rand_bits(&s);
        fprintf(fp, "%08x %08x %08x\n", a, b, fdiv_ref(a, b));
        cnt++;
    }

    fclose(fp);
    printf("wrote %d vectors to %s (directed=%d normal_rand=%d full_rand=%d seed=%u)\n",
           cnt, fn, cnt - 2 * N, N, N, seed);
    return 0;
}
