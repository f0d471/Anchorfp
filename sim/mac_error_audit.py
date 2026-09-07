#!/usr/bin/env python3
"""fp32_mac_unit 定点窗口的误差归因与定向反例。误差按来源分类计数，并给出跨块回灌的 K 趋势。

这一份回答的不是「误差有多大」，而是「误差从哪来」。
现有随机集相对无限精度参考的最大 ULP 是 0，但那只证明随机激励没打到边界，
不证明边界不存在。窗口能丢信息的路子有五条，五条的量级差着几十个二进制位，
只报一个总 ULP 无法归因，也就无法决定该修哪一条。

五类与 mac_win_model.STAT_KEYS 一一对应：

  1 align   对齐右移把一项的低位挤出窗口
  2 rescale 换基时累加器整体右移，丢掉低位
  3 negbias 上一条里被移的是负数，二补码算术右移向负无穷，与正数方向相反
  4 clr     raise_clr 重锚基准，把旧和整个丢掉
  5 xtile   跨 tile 经 FP32 回灌，按 tile 边界重复舍入

子命令
------
  vectors <类> <文件>   生成一类定向向量，格式与 gen_dot_vectors.py 相同，
                        tb_mac_win 直接吃，用来证明 RTL 与模型在这一类上逐位相同
  audit                 五类各跑一遍，报归因计数与 ULP，判定每类是否命中
  ktrend                K=64/128/256/512 分 tile 扫描，报 maxULP/P99/非零比例
  bound                 舍入前的误差界：独立大整数模型逐前缀检查三条不等式

判定口径见各子命令的注释。判据自身的注错见红由 run_mac_audit.sh 负责。
"""

import random
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
from mac_win_model import (win_dot, exact_dot, ulp_gap, new_stats,   # noqa: E402
                           geom, f2b, b2f, WIN_UP, WIN_G)

TW, ACCW = geom()
ONE = 0x3F800000            # 1.0f，定向向量一律用 x * 1.0 把乘积钉成 x 本身


def fp(sign, exp, frac):
    """按字段拼一个 FP32 位型。exp 是带偏置的 8 位阶码。"""
    return ((sign & 1) << 31) | ((exp & 0xFF) << 23) | (frac & 0x7FFFFF)


def randb(rng, emin, emax):
    return (rng.getrandbits(1) << 31) | ((rng.randint(emin, emax) & 0xFF) << 23) \
        | rng.getrandbits(23)


#-----------------------------------------------------------------------------
# 五类定向向量
#
# 每一类都必须真的把对应那条路径走热：生成完之后 audit 会核对该类的归因计数
# 大于零。计数为零说明向量退化了，这时判据即使全绿也没有意义。
#-----------------------------------------------------------------------------

def vec_halfway(rng, n=64):
    """第 1 类的可观测反例：对齐丢位破坏 RNE 的 sticky。

    三项 M + 0.5ulp(M) + tiny。精确和严格大于中点，正确答案是向上进位；
    但 tiny 的指数比 M 低 75 位，整项被挤出窗口，硬件看到的恰好是中点，
    于是按 RNE 向偶，M 尾数为偶时就停在 M 上，差一个 ULP。
    """
    out = []
    for _ in range(n):
        em = rng.randint(60, 190)
        frac = rng.getrandbits(23) & ~1          # 尾数末位取偶，让向偶=不进位
        big = fp(0, em, frac)
        half = fp(0, em - 24, 0)                 # 恰好 0.5 ULP
        tiny = fp(0, em - 75, 0)                 # 低到整项被移出窗口
        out.append((0, [big, ONE, half, ONE, tiny, ONE]))
    return out


def vec_tiny(rng, n=32, nterm=200):
    """第 1 类的累积档：一个大项后面跟一长串比它低 30 位以上的小项。

    每一项都触发对齐丢位，用来实测「单项丢位不超过一个窗口 LSB」这条界
    在 200 项累加下的实际累计量。
    """
    out = []
    for _ in range(n):
        em = rng.randint(80, 170)
        ab = [fp(0, em, rng.getrandbits(23)), ONE]
        for _ in range(nterm):
            # 指数低 33 到 70 位，全部落在 sh > TW-48 的丢位区
            ab += [fp(rng.getrandbits(1), em - rng.randint(33, 70),
                      rng.getrandbits(23)), ONE]
        out.append((0, ab))
    return out


def vec_mirror(rng, n=64, nterm=48):
    """第 3 类：同一组向量与它的全取反版本成对出现。

    二补码算术右移对负数向负无穷、对正数向零，两边的截断方向不同。
    若存在方向性偏差，镜像对的结果就不会严格互为相反数。
    audit 里按对检查，不是按条。
    """
    out = []
    for _ in range(n):
        em = rng.randint(90, 160)
        ab = []
        for k in range(nterm):
            # 指数逐段抬高，逼出多次换基；换基时累加器里已经有正有负
            e = em + (k // 8) * 20
            ab += [fp(rng.getrandbits(1), e, rng.getrandbits(23)), ONE]
        out.append((0, ab))
        out.append((0, [x ^ 0x80000000 if (i % 2 == 0) else x
                        for i, x in enumerate(ab)]))
    return out


def vec_cancel(rng, n=64):
    """第 4 类的确定性反例：raise_clr 之后高项自相抵消。

    psum 是一个不为零的小和 s，随后来一个比它高 100 位的 X 触发 raise_clr，
    s 被整个清掉；再来一个 -X 把 X 抵消干净。
    精确答案是 s，硬件给 0。这不是若干 ULP，是整个结果没了。

    注意这一族不需要 raise_clr 也能成立：把 100 换成 40 走的是普通 raise_any
    路径，s 被右移出窗口，结局一样。两个档都放进来。

    旧和的符号也交替。负的旧和走的是二补码算术右移那条向负无穷的路，
    与正的旧和不是同一条；只放正的进来，第 3 类就没有任何一条判据能碰到。

    X 之前先垫两个真乘积项，这一条是被判据逼出来的：psum 经 from_fp32 换算成
    mant48 时低 24 位是零填充，光有 psum 的旧和右移 48 位一位都不丢，
    rescale_drop 恒为 0，rescale_rtz 那个注入怎么都红不了。
    只有两个 24x24 的真积相加，累加器低位才有东西可丢。
    """
    out = []
    for i in range(n):
        es = rng.randint(40, 120)
        s = fp((i >> 1) & 1, es, rng.getrandbits(23))
        # 两个真乘积，指数贴着 s，把累加器低位填满
        p1 = [fp(0, es - 12, rng.getrandbits(23)), fp(0, 127 - 12, rng.getrandbits(23))]
        p2 = [fp(1, es - 13, rng.getrandbits(23)), fp(0, 127 - 11, rng.getrandbits(23))]
        gap = 100 if (i & 1) else 40             # 交替走 clr 档与普通换基档
        x = fp(0, es + gap, rng.getrandbits(23))
        out.append((s, p1 + p2 + [x, ONE, x ^ 0x80000000, ONE]))
    return out


def vec_xtile(rng, n=64, kdep=64):
    """第 5 类：跨 tile 回灌处的抵消。

    tile 0 里凑一个需要舍入的和 S，出口经 FP32 舍成 S'；
    tile 1 的头一项是 -S'，把它抵消掉，剩下的是若干微小项。
    最终结果由 S'-S 这个回灌误差主导，而不是由那些微小项主导。
    """
    out = []
    for _ in range(n):
        em = rng.randint(90, 150)
        ab = [fp(0, em, rng.getrandbits(23)), ONE]
        for _ in range(kdep - 1):
            ab += [fp(rng.getrandbits(1), em - rng.randint(1, 30),
                      rng.getrandbits(23)), ONE]
        s0, _ = win_dot(0, ab)                   # tile 0 出口的 FP32
        ab2 = [s0 ^ 0x80000000, ONE]
        for _ in range(kdep - 1):
            ab2 += [fp(rng.getrandbits(1), em - rng.randint(40, 60),
                       rng.getrandbits(23)), ONE]
        out.append((0, ab + ab2))
    return out


SPEC_K = 6
NZERO, PZERO = 0x80000000, 0x00000000
PINF, NINF, QNAN = 0x7F800000, 0xFF800000, 0x7FC00000
DENORM = 0x00000001          # 最小 denormal，按契约当带符号零
HUGE = fp(0, 254, 0x7FFFFF)  # 接近 FP32 上限
TINY = fp(0, 1, 0)           # 接近 FP32 下限


def vec_spec(rng=None, n=None):
    """把 datapath-manual 第 5.2 节的每一条数值契约摆成一条定向用例。

    这一类不查精度，查的是「文档说的和硬件做的是不是同一件事」。
    每条用例后面的注释就是它对应的契约原文，改契约必须同时改这里，
    否则文档与实现会各走各的而没有任何人发现。

    补位一律用 (-0) * (+0)：它是零项，不进窗口也不改 f_nz，
    而符号是负，不会把「全部参与项都是负零」这个条件意外拉正。
    """
    pad = [NZERO, PZERO]
    def mk(ab):
        return (ab + pad * SPEC_K)[:2 * SPEC_K]
    cases = [c for c, _ in _SPEC_TABLE(mk)]
    return cases


def _SPEC_TABLE(mk):
    """(用例, 期望标签) 对。标签而不是位型：位型要手算容易算错，
    标签是契约本身的名字，人工复核时对着手册一句一句读就行。"""
    return [
        # NaN 与 Inf 不进定点累加器，走旁路 sticky，末项组装时优先输出
        ((PZERO, mk([QNAN, ONE])),                     "qnan"),
        ((PZERO, mk([PINF, PZERO])),                   "qnan"),   # Inf * 0
        ((PZERO, mk([PINF, ONE, NINF, ONE])),          "qnan"),   # +Inf 与 -Inf 同在
        ((PZERO, mk([PINF, ONE, ONE, ONE])),           "pinf"),
        ((PZERO, mk([NINF, ONE, ONE, ONE])),           "ninf"),
        ((QNAN,  mk([ONE, ONE])),                      "qnan"),   # psum 是 NaN
        ((PINF,  mk([ONE, ONE])),                      "pinf"),
        ((NINF,  mk([ONE, ONE])),                      "ninf"),
        # 输入 denormal 按带符号零处理，不做 gradual underflow
        ((PZERO, mk([DENORM, ONE, ONE, ONE])),         "one"),    # 只剩 1*1
        ((PZERO, mk([DENORM, DENORM])),                "pzero"),
        ((PZERO, mk([DENORM | 0x80000000, ONE])),      "pzero"),  # psum 是 +0，把符号拉正
        # 结果 denormal 执行 FTZ，出带符号零
        ((PZERO, mk([TINY, TINY])),                    "pzero"),
        ((PZERO, mk([TINY, TINY ^ 0x80000000])),       "nzero"),  # 负的下溢保号
        # 上溢出 +-Inf
        ((PZERO, mk([HUGE, HUGE])),                    "pinf"),
        ((PZERO, mk([HUGE, HUGE ^ 0x80000000])),       "ninf"),
        # 精确得零时出 +0，除非全部参与项都是负零
        ((PZERO, mk([ONE, ONE, ONE, ONE ^ 0x80000000])), "pzero"),  # x + (-x)
        ((NZERO, mk([NZERO, PZERO])),                  "nzero"),  # 全是负零
        ((NZERO, mk([PZERO, PZERO])),                  "pzero"),  # 掺一个正零
        ((PZERO, mk([NZERO, PZERO])),                  "pzero"),  # psum 是 +0
        # 常规项与零项混合，零项不得把末项标记吞掉
        ((PZERO, mk([ONE, ONE, PZERO, PZERO])),        "one"),
    ]


SPEC_LABEL = {"qnan": QNAN, "pinf": PINF, "ninf": NINF,
              "pzero": PZERO, "nzero": NZERO, "one": ONE}


def spec_expect():
    """与 vec_spec 同序的期望位型。"""
    pad = [NZERO, PZERO]
    def mk(ab):
        return (ab + pad * SPEC_K)[:2 * SPEC_K]
    return [SPEC_LABEL[lab] for _, lab in _SPEC_TABLE(mk)]


CASES = {
    "spec":    (vec_spec,    "terms", SPEC_K,
                "FTZ/NaN/Inf/零符号/上溢的契约枚举"),
    "halfway": (vec_halfway, "align_drop", 3,
                "对齐丢位破坏 RNE 的 sticky"),
    "tiny":    (vec_tiny,    "align_drop", 201,
                "长串小项各自丢低位的累计量"),
    "mirror":  (vec_mirror,  "rescale_neg", 48,
                "负数换基的方向性偏差"),
    "cancel":  (vec_cancel,  "clr_drop", 4,
                "换基清旧和之后高项抵消"),
    "xtile":   (vec_xtile,   "align_drop", 128,
                "跨 tile 回灌处的抵消"),
}


def build(case, seed=20260906):
    """返回 (向量列表, K, KDEP)。KDEP 只有 xtile 一类与 K 不同。"""
    rng = random.Random(seed)
    gen, _, klen, _ = CASES[case]
    vs = gen(rng)
    kdep = 64 if case == "xtile" else klen
    return vs, klen, kdep


def emit(case, path, seed=20260906, inject=None):
    """写出 tb_mac_win 能吃的向量文件。exp 字段是逐位金标准，按块串 psum。

    inject 非空时，exp 由被注错的金标准算出，而 RTL 一字未改，
    于是 tb_mac_win 必须当场报 bad > 0。这是这五类判据自己的判据：
    判据抓不住金标准里的错，就更抓不住 RTL 里的错。
    向量本身（psum 与 a/b）与不注入时逐字节相同，变的只有期望值。
    """
    vs, klen, kdep = build(case, seed)
    with open(path, "w") as fh:
        for psum, ab in vs:
            assert len(ab) == 2 * klen, "%s: K 应为 %d，实为 %d" % (
                case, klen, len(ab) // 2)
            chain, res = psum, 0
            for base in range(0, klen, kdep):
                chain, r = win_dot(chain, ab[2 * base:2 * (base + kdep)],
                                   inject=inject)
                res |= int(r)
            fh.write("%08x %s %08x %d\n" % (
                psum, " ".join("%08x" % w for w in ab), chain, res))
    return klen, kdep, len(vs)


#-----------------------------------------------------------------------------
# 归因报告
#-----------------------------------------------------------------------------

def run_case(case, seed=20260906):
    """跑一类，返回 (统计字典, ULP 列表, 结果列表)。

    ULP 拿单块的无限精度参考量。xtile 一类硬件本来就要经 FP32 回灌，
    参考层仍取整段无限精度，这样量到的就是回灌那几次舍入的代价。
    """
    vs, klen, kdep = build(case, seed)
    st = new_stats()
    ulps, results = [], []
    for psum, ab in vs:
        chain = psum
        for base in range(0, klen, kdep):
            chain, _ = win_dot(chain, ab[2 * base:2 * (base + kdep)], stats=st)
        results.append(chain)
        ulps.append(ulp_gap(chain, exact_dot(psum, ab)))
    return st, ulps, results


def pct(vals, q):
    """第 q 百分位，vals 非空。取上界位序，样本少时不做插值。"""
    s = sorted(vals)
    i = min(len(s) - 1, int(len(s) * q / 100.0))
    return s[i]


def cmd_audit(seed=20260906):
    """五类各跑一遍。每类两条判定：目标路径必须被走热，ULP 必须落在预期档。

    预期档不是「越小越好」：cancel 一类的正确预期就是**大**，
    它是设计的固有代价，判据要求它确实大，才能证明这条反例是活的。
    """
    bad = 0
    print("==== fp32_mac_unit 窗口误差归因 ====")
    # 保护位不是一个定值：基准按 WIN_G 的量子上抬，最大项的 sh 落在
    # [WIN_UP, WIN_UP+WIN_G-1]，保护位随之在一个区间里，最坏取下界。
    # 这里曾按 sh 恒为 WIN_UP 打印单个数，那是 bound 报告证伪掉的那条前提。
    print("  TW=%d AccW=%d，最大项 LSB 之下的保护位 = %d 到 %d 位（最坏 %d）"
          % (TW, ACCW, TW - 48 - (WIN_UP + WIN_G - 1), TW - 48 - WIN_UP,
             TW - 48 - (WIN_UP + WIN_G - 1)))
    for case in ("halfway", "tiny", "mirror", "cancel", "xtile"):
        st, ulps, res = run_case(case, seed)
        key = CASES[case][1]
        hot = st[key]
        mx, p99 = max(ulps), pct(ulps, 99)
        nz = sum(1 for u in ulps if u)
        # 每类的预期：目标计数必须大于零；ULP 上界按类分档。
        # cancel 与 xtile 的正确预期是**大**：它们是抵消场景下的固有代价，
        # 判据要求它确实大，才能证明这两条反例是活的而不是构造失败。
        # 反过来 tiny 与 mirror 的预期是 0，它们证明的是另一半：
        # 无抵消时对齐丢位与负数换基在数值上不可观测。
        if case in ("cancel", "xtile"):
            ok_ulp, want = mx > 1000, "必须很大（抵消场景的固有代价）"
        elif case == "halfway":
            ok_ulp, want = mx <= 1, "<= 1（丢 sticky 最多差一个 ULP）"
        else:
            ok_ulp, want = mx == 0, "== 0（误差在 2^-46 * A 以下，见 bound 报告）"
        ok = hot > 0 and ok_ulp
        bad += 0 if ok else 1
        print("  %-8s %-28s %s=%-6d maxULP=%-10d P99=%-8d 非零=%d/%d  期望 %s -> %s"
              % (case, CASES[case][3], key, hot, mx, p99, nz, len(ulps),
                 want, "PASS" if ok else "FAIL"))
    # 契约枚举单独对账。这一类不比 ULP，比的是每条用例落在哪个契约档上
    _, _, sres = run_case("spec", seed)
    want = spec_expect()
    miss = [(i, sres[i], want[i]) for i in range(len(want)) if sres[i] != want[i]]
    bad += 0 if not miss else 1
    for i, got, exp in miss[:6]:
        print("  spec 第 %d 条不符契约: 得 %08x 期望 %08x" % (i, got, exp))
    print("  spec     FTZ/NaN/Inf/零符号/上溢的契约枚举   %d 条, 不符 %d 条 -> %s"
          % (len(want), len(miss), "PASS" if not miss else "FAIL"))

    # 镜像对要单独对账：结果必须严格互为相反数
    st, ulps, res = run_case("mirror", seed)
    asym = sum(1 for i in range(0, len(res) - 1, 2)
               if res[i] != (res[i + 1] ^ 0x80000000))
    bad += 0 if asym == 0 else 1
    print("  mirror   镜像对严格反号                 不对称对数=%d/%d -> %s"
          % (asym, len(res) // 2, "PASS" if asym == 0 else "FAIL"))
    print("SUMMARY mac_error_audit: 5 类 + 契约枚举 + 镜像对账, %d FAIL -> %s"
          % (bad, "PASS" if bad == 0 else "FAIL"))
    return bad


# 跨块回灌的验收界。这不是理论界：分块求和的误差正比于条件数
# sum|x| / |sum x|，条件数无界，所以任何只按块数写的界都是错的。
# 下面这一行是在 seed=20260906、nt=200、指数跨度 118..124 这组
# 激励上实测出来的最大值，再留一倍余量当回归闸门用：
# 它抓的是「以后改动把误差弄大了」，不是「误差在数学上不会超过它」。
KTREND_GATE = {64: 0, 128: 16, 256: 32, 512: 200}


def cmd_ktrend(seed=20260906, nt=200):
    """跨块回灌的代价随 K 怎么走。

    块深度恒为 64，K 变大就是块数变多。
    参考层恒取整段无限精度，所以量到的就是分块本身的代价。

    第三列是旧形态（同序 IEEE 逐项舍入，nacc=4）在同一组输入上的误差。
    没有这一列，这张表会被读成「窗口累加器在长 K 上不准」，
    而事实是同样的 K 下它比旧形态好一到两个数量级；
    跨 tile 那几次舍入是 psum 走 FP32 这个接口决定的，不是窗口决定的。
    """
    from mac_win_model import ieee_dot
    from fractions import Fraction
    bad = 0
    print("==== 跨块回灌的误差随 K ====")
    print("  tile 深度恒 64，参考层是整段无限精度点积；闸门是实测基线加余量，不是理论界")
    for K in (64, 128, 256, 512):
        rng = random.Random(seed + K)
        ulps, old_ulps, conds = [], [], []
        for _ in range(nt):
            emin, emax = 118, 124
            ab = []
            for _ in range(K):
                ab += [randb(rng, emin, emax), randb(rng, emin, emax)]
            chain = 0
            for base in range(0, K, 64):
                chain, _ = win_dot(chain, ab[2 * base:2 * (base + 64)])
            ex = exact_dot(0, ab)
            ulps.append(ulp_gap(chain, ex))
            old_ulps.append(ulp_gap(ieee_dot(0, ab), ex))
            # 条件数 sum|x| / |sum x|，用无限精度算，解释误差为什么随 K 涨
            s = Fraction(0)
            asum = Fraction(0)
            for j in range(K):
                v = Fraction(b2f(ab[2 * j])) * Fraction(b2f(ab[2 * j + 1]))
                s += v
                asum += abs(v)
            conds.append(float(asum / abs(s)) if s else 0.0)
        mx, p99 = max(ulps), pct(ulps, 99)
        nz = sum(1 for u in ulps if u)
        ntile = K // 64
        lim = KTREND_GATE[K]
        ok = mx <= lim
        bad += 0 if ok else 1
        print("  K=%-4d tile数=%-2d maxULP=%-4d P99=%-4d 非零=%3d/%d 闸门=%-4d "
              "旧形态maxULP=%-6d 条件数中位=%.1f -> %s"
              % (K, ntile, mx, p99, nz, nt, lim, max(old_ulps),
                 pct(conds, 50), "PASS" if ok else "FAIL"))
    print("SUMMARY mac_ktrend: 4 档 K, %d FAIL -> %s"
          % (bad, "PASS" if bad == 0 else "FAIL"))
    return bad


def _wb_term(x):
    """FP32 位型 -> (符号, 48 位尾数, 阶码)。非正规与特殊值不进定点累加器"""
    e = (x >> 23) & 255
    if e in (0, 255):
        return None
    return (-1 if x >> 31 else 1, ((1 << 23) | (x & 0x7FFFFF)) << 24, e - 1)


def _wb_product(a, b):
    ea, eb = (a >> 23) & 255, (b >> 23) & 255
    if ea in (0, 255) or eb in (0, 255):
        return None
    return (-1 if (a ^ b) >> 31 else 1,
            ((1 << 23) | (a & 0x7FFFFF)) * ((1 << 23) | (b & 0x7FFFFF)),
            ea + eb - 127)


def cmd_bound(seed=20260906, nt=2000):
    """窗口累加在舍入之前的误差界，逐前缀检查。

    契约（手册 B 档）：对有限项 S = sum(t_i)、A = sum(|t_i|)，
    要求 |Z - S| <= 2^-32 * A，Z 是末项舍入之前的窗口累加值。

    推导：窗口最低位的实数权重 lambda = 2^(B-205)。基准的不变式给出
    Emax + WinUp <= B <= Emax + WinUp + WinG - 1，于是 lambda <= 2^-55 * M
    （M 是最大项的绝对值）。每项对齐丢位与每次换基各引入不超过一个 lambda，
    N 项合计 |Z - S| < 2N * lambda <= 2^-46 * M <= 2^-46 * A，
    相对契约要求的 2^-32 还有 14 位余量。

    要点是本函数**不调用本目录的逐位模型**，用独立的大整数实现从头再算一遍。
    两层共用一份代码，就不可能靠「两层都过」发现那份代码本身的问题。

    原来这里写的是「最大项的 sh 恒为 WinUp = 8，所以累计误差 2^-40 个 ULP」。
    那条推导是错的：基准按 WinG = 16 的量子上抬，sh 最大取到 23；而且它默认
    结果的 ULP 落在窗口第 48 位，抵消时并不成立。
    """
    rng = random.Random(seed)
    cases = rescales = clears = 0
    max_sh = 0
    worst_local = 0.0        # max |Z-S| / (2N * lambda)，理论界是 1
    worst_budget = 0.0       # max |Z-S| * 2^32 / A，契约界是 1
    fails = []

    def check(ps, ab):
        nonlocal cases, rescales, clears, max_sh, worst_local, worst_budget
        terms = [t for t in [_wb_term(ps)] +
                 [_wb_product(ab[i], ab[i + 1]) for i in range(0, len(ab), 2)]
                 if t is not None]
        if not terms:
            return
        acc = 0
        base = None
        ideal = 0
        absolute = 0
        maxmag = 0
        for n, (sg, m, e) in enumerate(terms, 1):
            need = e + 8 - base if base is not None else 0
            if base is None:
                base = e + 8
            elif need > 87:
                base = e + 8
                acc = 0
                clears += 1
            elif need > 0:
                shift = ((need + 15) // 16) * 16
                base += shift
                acc = 0 if shift >= 88 else acc >> shift
                rescales += 1
            sh = base - e
            acc += sg * ((m << 32) >> sh)
            if not -(1 << 87) <= acc < (1 << 87):
                fails.append("累加器溢出")
            value = sg * (m << (e + 227))
            ideal += value
            absolute += abs(value)
            maxmag = max(maxmag, abs(value))
            lam = 1 << (base + 195)
            error = abs(acc * lam - ideal)
            if error >= 2 * n * lam:
                fails.append("逐项截断界不成立")
            if (lam << 55) > maxmag:
                fails.append("lambda <= 2^-55 * M 不成立")
            if (error << 32) > absolute:
                fails.append("契约界 2^-32 * A 不成立")
            max_sh = max(max_sh, base - max(t[2] for t in terms[:n]))
            worst_local = max(worst_local, error / (2 * n * lam))
            if absolute:
                worst_budget = max(worst_budget, (error << 32) / absolute)
        cases += 1

    # 五类定向反例先走一遍，它们才是最不利的形状
    for name in ("halfway", "tiny", "mirror", "cancel", "xtile"):
        vs, _klen, _kdep = build(name)
        for ps, ab in vs:
            check(ps, ab)

    for i in range(nt):
        k = (1, 4, 64, 128, 254)[i % 5]
        ab = []
        for _ in range(k):
            ab.append((rng.getrandbits(1) << 31) | (rng.randint(1, 254) << 23)
                      | rng.getrandbits(23))
            ab.append((rng.getrandbits(1) << 31) | (rng.randint(1, 254) << 23)
                      | rng.getrandbits(23))
        ps = (rng.getrandbits(1) << 31) | (rng.randint(1, 254) << 23) | rng.getrandbits(23)
        check(ps, ab)

    ok = not fails
    print("==== 窗口累加在舍入之前的误差界 ====")
    print("  独立大整数模型，逐前缀检查；不调用本目录的逐位模型")
    print("  %d 组，换基 %d 次，清空 %d 次，最大项的 sh 实测最大 %d（不是恒为 8）"
          % (cases, rescales, clears, max_sh))
    print("  |Z-S| / (2N*lambda) 实测最大 %.6g，理论界 1" % worst_local)
    print("  |Z-S| * 2^32 / A    实测最大 %.6g，契约界 1" % worst_budget)
    if fails:
        for f in sorted(set(fails)):
            print("  不成立：%s" % f)
    print("SUMMARY mac_window_bound: %d 组逐前缀检查, %d 条不等式不成立 -> %s"
          % (cases, len(set(fails)), "PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    av = sys.argv
    if len(av) > 1 and av[1] == "vectors":
        inj = av[4] if len(av) > 4 and av[4] != "-" else None
        klen, kdep, n = emit(av[2], av[3], inject=inj)
        sys.stderr.write("VEC %s: K=%d KDEP=%d 条数=%d 注入=%s -> %s\n"
                         % (av[2], klen, kdep, n, inj or "无", av[3]))
        print("%d %d" % (klen, kdep))
        return 0
    if len(av) > 1 and av[1] == "ktrend":
        return cmd_ktrend()
    if len(av) > 1 and av[1] == "bound":
        return cmd_bound()
    return cmd_audit()


if __name__ == "__main__":
    sys.exit(main())
