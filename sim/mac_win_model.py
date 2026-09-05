#!/usr/bin/env python3
"""fp32_mac_unit 定点窗口累加的金标准，两层。

第一层 win_dot()   逐位守门人。用 Python 大整数精确复刻硬件：基准推导与上调、
                   逐项对齐、累加器算术右移、末项 RNE。硬件与它必须逐位相同。
第二层 exact_dot() 无限精度参考。用 Fraction 精确求和后一次正确舍入到 FP32，
                   用来证明窗口够宽 —— 第一层与它的差就是窗口造成的全部误差。

第三个是 ieee_dot()，复刻同序 IEEE 逐项累加，
用来回答「新形态的误差是不是真的不大于旧形态」这个验收问题。

为什么不用 C：窗口宽度是设计参数，AccW 一旦超过 128 位，__int128 就装不下了，
而第二层本来就需要任意精度。两层写在一处也少一份走样的机会。

参数须与 RTL 的 fp32_mac_unit 例化参数一致。

误差归因
--------
win_dot() 接一个可选的 stats 字典，把窗口丢掉的信息按来源分开计数。
只报一个总 ULP 是无法归因的：同一个 ULP 可能来自五条完全不同的路径，
修其中一条不会动另外四条。计数口径见 new_stats() 的注释。
"""

import struct
from fractions import Fraction

# 与 RTL 的默认例化参数一致
WIN_UP = 8
WIN_G = 16
WIN_FRAC = 8


def geom(win_up=WIN_UP, win_g=WIN_G, win_frac=WIN_FRAC):
    """返回 (TW, AccW)。与 RTL 的 localparam 同式。"""
    tw = 48 + win_up + win_g + win_frac
    return tw, tw + 8


# 五类信息损失。名字与 Todo fp32-mac-window-accuracy-closure.md 的五条一一对应，
# 改名要同时改那一份，否则报告读不成对照
STAT_KEYS = (
    "align_drop",     # 1 对齐右移丢掉了非零低位的项数
    "align_kill",     # 1 的极端档：整项被移出窗口，进窗口的量恒为零
    "rescale_drop",   # 2/3 换基算术右移丢掉了非零低位的次数
    "rescale_neg",    # 3 上一条里被移的旧和是负数，截断方向与正数相反
    "clr_drop",       # 4 raise_clr 清掉的旧和本身非零
    "raise_any",      # 基准移动事件数，即 RTL 的 win_rescale 置位来源
    "terms",          # 进过窗口的常规项数，做分母用
)


def new_stats():
    """一份归零的归因计数。传给 win_dot(stats=...) 就地累加。

    raise_any 与前五项的关系是本模型要说清的第一件事：
    RTL 的 win_rescale 报的是 raise_any，即「基准移动过」，
    它既不蕴含也不被蕴含于「真的丢了非零位」——
    基准移动而移出位全零时它假阳性，普通项对齐丢位时它假阴性。
    """
    return dict.fromkeys(STAT_KEYS, 0)


def f2b(x):
    """FP64 -> FP32 位型。超出 FP32 范围时钳到 +-Inf，与硬件的上溢语义一致
    （宿主的 struct.pack 在这里会直接抛 OverflowError）。"""
    try:
        return struct.unpack("<I", struct.pack("<f", x))[0]
    except OverflowError:
        return 0xFF800000 if x < 0 else 0x7F800000


def b2f(u):
    return struct.unpack("<f", struct.pack("<I", u & 0xFFFFFFFF))[0]


class Term:
    __slots__ = ("nan", "inf", "zero", "sign", "mant48", "e")

    def __init__(self, nan, inf, zero, sign, mant48, e):
        self.nan, self.inf, self.zero = nan, inf, zero
        self.sign, self.mant48, self.e = sign, mant48, e

    def value(self):
        """精确值，Fraction。只对常规项有意义。"""
        return Fraction(self.mant48) * Fraction(2) ** (self.e - 173) * (-1 if self.sign else 1)


def from_fp32(x):
    """把 IEEE FP32 位型换算到统一刻度：mant48 = {1,frac} << 24，e = exp - 1。"""
    ex, fr, sg = (x >> 23) & 0xFF, x & 0x7FFFFF, (x >> 31) & 1
    return Term(nan=(ex == 0xFF and fr != 0),
                inf=(ex == 0xFF and fr == 0),
                zero=(ex == 0),
                sign=sg,
                mant48=(0x800000 | fr) << 24,
                e=ex - 1)


def prod(a, b, fuse=True):
    """乘积项。fuse 取乘法器第 1 级的未舍入 48 位积，否则取舍入后的 p 再拆包。"""
    ea, fa, sa = (a >> 23) & 0xFF, a & 0x7FFFFF, (a >> 31) & 1
    eb, fb, sb = (b >> 23) & 0xFF, b & 0x7FFFFF, (b >> 31) & 1
    a_nan, b_nan = (ea == 0xFF and fa != 0), (eb == 0xFF and fb != 0)
    a_inf, b_inf = (ea == 0xFF and fa == 0), (eb == 0xFF and fb == 0)
    a_zro, b_zro = (ea == 0), (eb == 0)

    nan = a_nan or b_nan or ((a_inf or b_inf) and (a_zro or b_zro))
    inf = (a_inf or b_inf) and not nan
    zero = (a_zro or b_zro) and not nan and not inf
    if nan or inf or zero:
        return Term(nan, inf, zero, sa ^ sb, 0, 0)
    if fuse:
        return Term(False, False, False, sa ^ sb,
                    (0x800000 | fa) * (0x800000 | fb), ea + eb - 127)
    # 非融合：项源是乘法器第 2 级的输出。本仓的 fp32_mul_pipe 是 RNE + FTZ，
    # 输入 denormal 上面已判成 zero，结果 denormal 与上溢在这里显式钳掉
    p = b2f(a) * b2f(b)
    pb = f2b(p)
    pe = (pb >> 23) & 0xFF
    if pe == 0xFF:
        return Term(False, True, False, (pb >> 31) & 1, 0, 0)
    if pe == 0:
        return Term(False, False, True, (pb >> 31) & 1, 0, 0)
    return from_fp32(pb)


def _pack(sign, mag, base, tw, accw, trunc=False):
    """把累加器的定点值组装回 IEEE FP32，RNE + FTZ。trunc 是注错见红用的截断档。"""
    m = mag.bit_length() - 1
    mn = mag << (accw - 1 - m)
    top24 = mn >> (accw - 24)
    guard = (mn >> (accw - 25)) & 1
    stky = (mn & ((1 << (accw - 25)) - 1)) != 0
    lsb = top24 & 1
    m_rnd = top24 + (0 if trunc else (1 if (guard and (stky or lsb)) else 0))
    m_ovf = (m_rnd >> 24) & 1
    frac = 0 if m_ovf else (m_rnd & 0x7FFFFF)
    exp_b = m + base - (tw - 2) + m_ovf
    if exp_b >= 255:
        return (sign << 31) | 0x7F800000
    if exp_b <= 0:
        return sign << 31
    return (sign << 31) | (exp_b << 23) | frac


# 金标准自己的注错见红点。键是注入名，值是这一注入改坏了哪条数值路径
INJECTS = {
    "align_jam":   "对齐丢位时把进窗口的量末位置 1，即给移出位补一个 jam",
    "rescale_rtz": "换基右移改成向零截断，消掉负数向负无穷的方向性",
    "clr_keep":    "raise_clr 不清空旧和，改成右移到窗口底仍保留",
    "pack_trunc":  "末项舍入由 RNE 改成截断",
    "win_pad":     "窗口下方多留 8 位保护位",
}


def win_dot(psum, ab, fuse=True, win_up=WIN_UP, win_g=WIN_G, win_frac=WIN_FRAC,
            stats=None, inject=None):
    """第一层：逐位复刻硬件。返回 (结果位型, 是否抬过基准)。

    stats 给一份 new_stats() 就地累加五类信息损失，不给则只算结果。
    统计与数值互不影响：加统计不会改任何一位输出。

    inject 取 INJECTS 里的一个键，就地改坏本模型的一条数值路径。
    它不是给产线用的：金标准自己也要能被证伪，注一个错进来之后
    「RTL 与本模型逐位相同」这条判据必须当场红，否则那条判据是摆设。
    """
    if inject is not None and inject not in INJECTS:
        raise ValueError("未知的注入点 %s，可选 %s" % (inject, ",".join(INJECTS)))
    tw, accw = geom(win_up, win_g, win_frac)
    if inject == "win_pad":
        tw, accw = tw + 8, accw + 8
    mask = (1 << accw) - 1
    acc = 0                     # 补码，始终截到 accw 位
    base, base_valid = 0, False
    f_nan = f_infp = f_infn = f_nz = False
    f_zsgn, f_res = 1, False

    ps = from_fp32(psum)
    if ps.nan:
        f_nan = True
    elif ps.inf:
        if ps.sign:
            f_infn = True
        else:
            f_infp = True
    elif ps.zero:
        f_zsgn &= ps.sign
    else:
        f_nz = True
        base, base_valid = ps.e + win_up, True
        mag = ps.mant48 << (win_g + win_frac)   # 移位量恒为 win_up
        acc = (acc + (-mag if ps.sign else mag)) & mask
        if stats is not None:
            stats["terms"] += 1                 # psum 移位量恒为 win_up，不可能丢位

    for k in range(len(ab) // 2):
        t = prod(ab[2 * k], ab[2 * k + 1], fuse)
        if t.nan:
            f_nan = True
            continue
        if t.inf:
            if t.sign:
                f_infn = True
            else:
                f_infp = True
            continue
        if t.zero:
            f_zsgn &= t.sign
            continue
        f_nz = True

        # 基准跟着运行最大值走：不够就按 win_g 的量子抬，累加器同拍右移同样位数
        if not base_valid:
            base, base_valid = t.e + win_up, True
            shift, clr = 0, False
        else:
            need = t.e + win_up - base
            if need <= 0:
                shift, clr = 0, False
            elif need > accw - 1:
                base, shift, clr = t.e + win_up, 0, True
                f_res = True
            else:
                dq = -(-need // win_g)          # ceil
                base += dq * win_g
                shift, clr = dq * win_g, False
                f_res = True

        if stats is not None and (clr or shift):
            stats["raise_any"] += 1

        if clr or shift >= accw:
            if stats is not None and acc:
                # 旧和不是数学上的零，被整个丢掉。第 4 类
                stats["clr_drop"] += 1
            if inject == "clr_keep" and acc:
                pass            # 旧和原地留着，基准却已经重锚，刻度对不上
            else:
                acc = 0
        elif shift:
            sv = acc - (1 << accw) if (acc >> (accw - 1)) else acc
            if stats is not None and (acc & ((1 << shift) - 1)):
                # 换基右移真的丢了非零低位。第 2 类；旧和为负时截断方向相反，第 3 类
                stats["rescale_drop"] += 1
                if sv < 0:
                    stats["rescale_neg"] += 1
            if inject == "rescale_rtz":
                q = abs(sv) >> shift            # 向零截断，正负对称
                acc = (-q if sv < 0 else q) & mask
            else:
                acc = (sv >> shift) & mask      # 算术右移，向 -inf 截断

        sh = base - t.e
        full = t.mant48 << (tw - 48)
        mag = 0 if sh > accw - 1 else (full >> sh)
        lost = sh > 0 and bool(full & ((1 << sh) - 1))
        if stats is not None:
            stats["terms"] += 1
            # 第 1 类：对齐右移把这一项的低位挤出窗口。sh <= tw-48 时窗口下方
            # 的保护位接得住，一位都不丢
            if lost:
                stats["align_drop"] += 1
            if mag == 0:
                stats["align_kill"] += 1   # align_drop 的子集，不是独立一类
        if inject == "align_jam" and lost:
            mag |= 1
        acc = (acc + (-mag if t.sign else mag)) & mask

    if f_nan or (f_infp and f_infn):
        return 0x7FC00000, f_res
    if f_infp:
        return 0x7F800000, f_res
    if f_infn:
        return 0xFF800000, f_res

    neg = (acc >> (accw - 1)) & 1
    mag = ((~acc + 1) & mask) if neg else acc
    if mag == 0:
        return ((0 if f_nz else f_zsgn) << 31), f_res
    return _pack(neg, mag, base, tw, accw, trunc=(inject == "pack_trunc")), f_res


def _rne(fr):
    """把一个 Fraction 正确舍入到 FP32（RNE），下溢按 FTZ 出 +-0。"""
    if fr == 0:
        return 0
    sign = 1 if fr < 0 else 0
    v = -fr if fr < 0 else fr
    e = 0
    while v >= 2:
        v /= 2
        e += 1
    while v < 1:
        v *= 2
        e -= 1
    # v 落在 [1,2)，取 24 位有效数字
    scaled = v * (1 << 23)
    q = scaled.numerator // scaled.denominator
    rem = scaled - q
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and (q & 1)):
        q += 1
    if q >= (1 << 24):
        q >>= 1
        e += 1
    exp_b = e + 127
    if exp_b >= 255:
        return (sign << 31) | 0x7F800000
    if exp_b <= 0:
        return sign << 31
    return (sign << 31) | (exp_b << 23) | (q & 0x7FFFFF)


def exact_dot(psum, ab, fuse=True):
    """第二层：无限精度求和后一次正确舍入。特殊值语义与第一层一致。"""
    f_nan = f_infp = f_infn = False
    acc = Fraction(0)
    ps = from_fp32(psum)
    if ps.nan:
        f_nan = True
    elif ps.inf:
        if ps.sign:
            f_infn = True
        else:
            f_infp = True
    elif not ps.zero:
        acc += ps.value()
    for k in range(len(ab) // 2):
        t = prod(ab[2 * k], ab[2 * k + 1], fuse)
        if t.nan:
            f_nan = True
        elif t.inf:
            if t.sign:
                f_infn = True
            else:
                f_infp = True
        elif not t.zero:
            acc += t.value()
    if f_nan or (f_infp and f_infn):
        return 0x7FC00000
    if f_infp:
        return 0x7F800000
    if f_infn:
        return 0xFF800000
    return _rne(acc)


def ieee_dot(psum, ab, nacc=4):
    """旧形态：项号对 nacc 取模交错，逐项 IEEE 舍入，喂完两两归约。

    用宿主的 float 做，与旧 gen_dot_vectors.c 的 -ffp-contract=off 等价：
    Python 的 float 是 FP64，所以每一步都显式截回 FP32。
    """
    acc = [0.0] * nacc
    acc[0] = b2f(psum)
    n = len(ab) // 2
    for k in range(n):
        p = b2f(f2b(b2f(ab[2 * k]) * b2f(ab[2 * k + 1])))
        acc[k % nacc] = b2f(f2b(acc[k % nacc] + p))
    live = nacc
    while live > 1:
        for p in range(live // 2):
            acc[p] = b2f(f2b(acc[2 * p] + acc[2 * p + 1]))
        live //= 2
    return f2b(acc[0])


def ulp_gap(x, y):
    """两个 FP32 位型之间的 ULP 距离。异号或含 NaN 时给一个大数。"""
    if ((x >> 23) & 0xFF) == 0xFF or ((y >> 23) & 0xFF) == 0xFF:
        return 0 if x == y else 1 << 30
    def key(u):
        return (u ^ 0x7FFFFFFF) - 0x7FFFFFFF if (u >> 31) else u
    return abs(key(x) - key(y))
