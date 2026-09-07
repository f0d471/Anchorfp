// gen_denorm_vectors.c —— denormal 与极小值向量的金标准生成器
//
// 期望值按 FTZ 契约算，不是完整 IEEE：
//   输入 denormal（exp == 0）  按 ±0 参与运算，符号保留
//   输出 denormal              flush 成 ±0，符号保留
//   Inf x 0 / Inf x denormal   出 qNaN
//
// 用法: gcc -O2 -ffp-contract=off -o gen_denorm gen_denorm_vectors.c && ./gen_denorm > vectors_denorm.txt

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint32_t f2b(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    b2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

/* FTZ：exp 域全 0（denormal 与 ±0）一律当 ±0，符号保留。
 * 与 gen_ftz_vectors.c 逐字同一份实现 —— 一个契约只写一遍。 */
static inline float ftz(float x)
{
    uint32_t b = f2b(x);
    return ((b & 0x7F800000u) == 0u) ? b2f(b & 0x80000000u) : x;
}

/* 硬件契约参考实现：输入各 flush 一次、输出再 flush 一次。
 * x86 原生是完整 IEEE，所以这两层 ftz() 就是硬件与 host 的**全部**差异。 */
static float ref_mul(float a, float b) { return ftz(ftz(a) * ftz(b)); }
static float ref_add(float a, float b) { return ftz(ftz(a) + ftz(b)); }

int main(void) {
    int cnt = 0;

    // ========== 1. 典型 denormal 输入 ==========
    // denormal 格式: exp=0, frac≠0, 值 = 0.f × 2^(-126)
    uint32_t denorm_values[] = {
        0x00000001,  // 最小正 denormal: 2^(-149) ≈ 1.4e-45
        0x00000002,  // 2 × 2^(-149)
        0x0000000F,  // 较大 denormal
        0x000000FF,
        0x00000FFF,
        0x000FFFFF,
        0x001FFFFF,
        0x003FFFFF,
        0x007FFFFF,  // 最大 denormal: ≈ 1.18e-38
        0x00400000,  // 仍是 denormal(exp=0)！原注释误标为"最小规格化"——
                     //    最小规格化数是 0x00800000。FTZ 下这条也应 flush 成 +0。
    };
    int ndenorm = (int)(sizeof(denorm_values) / sizeof(denorm_values[0]));

    // ========== 2. denormal × denormal ==========
    //   FTZ 期望：两个操作数都 flush 成 ±0 ⇒ 积恒为 ±0
    //   （旧期望是 IEEE 的极小积；那正是 fp32_mul_norm 5 位前导零装不下的那批）
    for (int i = 0; i < ndenorm; i++) {
        for (int j = 0; j < ndenorm; j++) {
            float a = b2f(denorm_values[i]);
            float b = b2f(denorm_values[j]);
            printf("M %08x %08x %08x\n", f2b(a), f2b(b), f2b(ref_mul(a, b)));
            cnt++;
        }
    }

    // ========== 3. denormal × 规格化小值 ==========
    //   FTZ 期望：denormal 侧 flush 成 ±0 ⇒ 积恒为 ±0
    float small_normals[] = { b2f(0x00800000), b2f(0x01000000), b2f(0x01800000),
                              b2f(0x02000000), b2f(0x02800000) };
    for (int i = 0; i < ndenorm; i++) {
        for (int k = 0; k < 5; k++) {
            float a = b2f(denorm_values[i]);
            printf("M %08x %08x %08x\n", f2b(a), f2b(small_normals[k]), f2b(ref_mul(a, small_normals[k])));
            cnt++;
        }
    }

    // ========== 4. fpadd: denormal + denormal ==========
    //   FTZ 期望：两侧都 flush 成 +0 ⇒ 和恒为 +0
    for (int i = 0; i < ndenorm; i++) {
        for (int j = 0; j < ndenorm; j++) {
            float a = b2f(denorm_values[i] & 0x7FFFFFFFu);  // 正 denormal
            float b = b2f(denorm_values[j] & 0x7FFFFFFFu);
            printf("A %08x %08x %08x\n", f2b(a), f2b(b), f2b(ref_add(a, b)));
            cnt++;
        }
    }

    // ========== 5. 边界: 最小 denormal 平方 ==========
    {
        float t = b2f(0x00000001);
        printf("M %08x %08x %08x\n", f2b(t), f2b(t), f2b(ref_mul(t, t)));
        cnt++;
    }

    // ========== 6. denormal × 1.0 ==========
    //   判据在 V1-C 反转：旧期望"应精确"(= denormal 原值)，
    //      FTZ 期望是 **±0**（输入被 flush）。
    {
        float one = 1.0f;
        for (int i = 0; i < ndenorm; i++) {
            float a = b2f(denorm_values[i]);
            printf("M %08x %08x %08x\n", f2b(a), f2b(one), f2b(ref_mul(a, one)));
            cnt++;
        }
    }

    // ========== 7. [新] 负 denormal 的符号保留 ==========
    //   FTZ 保符号：(-denormal) × (+2.0) = -0；(-denormal) + (-denormal) = -0
    {
        float two = 2.0f;
        for (int i = 0; i < ndenorm; i++) {
            float na = b2f(denorm_values[i] | 0x80000000u);
            printf("M %08x %08x %08x\n", f2b(na), f2b(two), f2b(ref_mul(na, two)));
            cnt++;
            printf("A %08x %08x %08x\n", f2b(na), f2b(na), f2b(ref_add(na, na)));
            cnt++;
        }
    }

    // ========== 8. [新] Inf × denormal → qNaN（V1-C 引入的新冲突面）==========
    //   host 的 Inf*denormal 是 ±Inf（denormal 非零），**不能用它当期望**，
    //   这里直接钉死契约值 0x7FC00000。TB 对 NaN 只判分类。
    {
        printf("M %08x %08x %08x\n", 0x7F800000u, 0x00000001u, 0x7FC00000u);
        printf("M %08x %08x %08x\n", 0xFF800000u, 0x007FFFFFu, 0x7FC00000u);
        cnt += 2;
    }

    fprintf(stderr, "generated %d test vectors (FTZ contract)\n", cnt);
    return 0;
}
