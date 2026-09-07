#!/usr/bin/env python3
"""fp32_mac_unit 的点积激励生成器。

1. 按模式生成：常规 / 极小 / 特殊值 / 宽跨度，逐行输出 a_bits b_bits。
2. fuse=0 与 fuse=1 用同一批向量，两档之差即融合乘加单独买到的精度。
3. 向量是派生数据，不入库。
"""
import random
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
from mac_win_model import win_dot, exact_dot, ieee_dot, ulp_gap   # noqa: E402

SPECIALS = [0x7F800000, 0xFF800000, 0x7FC00000,
            0x00000000, 0x80000000, 0x00000001]


def randb(rng, emin, emax):
    return (rng.getrandbits(1) << 31) | ((rng.randint(emin, emax) & 0xFF) << 23) \
        | rng.getrandbits(23)


def main():
    av = sys.argv
    K = int(av[1]) if len(av) > 1 else 64
    NT = int(av[2]) if len(av) > 2 else 3000
    seed = int(av[3]) if len(av) > 3 else 12345
    zero_psum = int(av[4]) if len(av) > 4 else 0
    mode = int(av[5]) if len(av) > 5 else 0
    kdep = int(av[6]) if len(av) > 6 else K
    # fuse=0 是对照档：乘积侧仍按 IEEE 舍入一次再进窗口
    fuse = bool(int(av[7])) if len(av) > 7 else True
    if kdep < 1 or K % kdep:
        sys.exit("kdep 必须整除 K")

    rng = random.Random(seed)
    out = []
    max_ulp_win = max_ulp_ieee = 0
    n_res = 0

    for t in range(NT):
        emin, emax = (100, 140) if (t & 1) else (118, 124)
        psum = 0 if (zero_psum or t % 3 == 0) else randb(rng, emin, emax)
        ab = []
        for k in range(K):
            if mode == 1:
                if (k & 3) == 0:
                    x, y = randb(rng, 0, 8), randb(rng, 0, 8)
                else:
                    x, y = randb(rng, emin, emax), randb(rng, emin, emax)
            elif mode == 2:
                if (k & 15) == 0:
                    x, y = rng.choice(SPECIALS), rng.choice(SPECIALS)
                elif (k & 7) == 0:
                    x, y = rng.choice(SPECIALS), randb(rng, emin, emax)
                else:
                    x, y = randb(rng, emin, emax), randb(rng, emin, emax)
            elif mode == 3:
                # 首项极小定基准，随后几项极大：乘积指数跨度约 210 位，
                # 固定基准的窗口必然撑破，动态基准要靠上调接住
                if k == 0:
                    x, y = randb(rng, 70, 74), randb(rng, 70, 74)
                elif k < 4:
                    x, y = randb(rng, 175, 180), randb(rng, 175, 180)
                else:
                    x, y = randb(rng, 70, 80), randb(rng, 70, 80)
            else:
                x, y = randb(rng, emin, emax), randb(rng, emin, emax)
            ab += [x, y]

        # 逐块算，块间把上一块的结果当下一块的 psum（硬件就是这么串的）
        chain, res_any = psum, 0
        for base in range(0, K, kdep):
            chain, r = win_dot(chain, ab[2 * base:2 * (base + kdep)], fuse)
            res_any |= int(r)
        n_res += res_any

        line = "%08x " % psum + " ".join("%08x %08x" % (ab[2 * k], ab[2 * k + 1])
                                         for k in range(K))
        out.append("%s %08x %d" % (line, chain, res_any))

        # 第二层对账只在单块时做：多块之间硬件本来就要经 FP32 回灌，
        # 那几次舍入不属于窗口的账
        # 参考层恒取原始 a,b 的无限精度点积（乘积也不舍入），
        # 这样 fuse=0 与 fuse=1 是拿同一把尺子量的，融合的收益才看得见
        if kdep == K and mode in (0, 1, 3):
            ex = exact_dot(psum, ab)
            max_ulp_win = max(max_ulp_win, ulp_gap(chain, ex))
            max_ulp_ieee = max(max_ulp_ieee, ulp_gap(ieee_dot(psum, ab), ex))

    sys.stdout.write("\n".join(out) + "\n")
    if kdep == K and mode in (0, 1, 3):
        sys.stderr.write(
            "REF K=%d NT=%d mode=%d fuse=%d 抬基准=%d/%d  "
            "窗口 vs 无限精度 maxULP=%d   旧形态(同序IEEE nacc=4) vs 无限精度 maxULP=%d -> %s\n"
            % (K, NT, mode, int(fuse), n_res, NT, max_ulp_win, max_ulp_ieee,
               "PASS" if max_ulp_win <= max_ulp_ieee else "FAIL"))


if __name__ == "__main__":
    main()
