#!/usr/bin/env python3
"""用独立数学参考复核 tb_sfu_golden 的 RTL 输出：误差上限与特殊值契约。

冻结参考只判断行为是否变化，本脚本判断行为在数学上是否合格，两者不能互相替代。
"""

from __future__ import annotations

import argparse
import math
import re
import struct
import sys
from pathlib import Path


LINE_RE = re.compile(
    r"^\d+ in=([0-9a-fA-F]{8}) exp=([0-9a-fA-F]{8}) "
    r"sin=([0-9a-fA-F]{8}) rsqrt=([0-9a-fA-F]{8}) cos=([0-9a-fA-F]{8})$"
)


def bits_to_float(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def is_nan(bits: int) -> bool:
    return (bits & 0x7F800000) == 0x7F800000 and (bits & 0x007FFFFF) != 0


def check_special(inp: int, exp: int, sin: int, rsqrt: int, cos: int) -> list[str]:
    errors = []
    sign = inp >> 31
    exponent = (inp >> 23) & 0xFF
    mantissa = inp & 0x7FFFFF

    if exponent == 0xFF and mantissa != 0:
        for name, value in (("exp", exp), ("sin", sin), ("cos", cos), ("rsqrt", rsqrt)):
            if value != 0x7FC00000:
                errors.append(f"{name}(NaN {inp:08x})={value:08x}, expected canonical qNaN")
    if exponent == 0xFF and mantissa == 0:
        if sin != 0x7FC00000 or cos != 0x7FC00000:
            errors.append(f"trig(Inf {inp:08x}) did not return canonical qNaN")
        expected_exp = 0x00000000 if sign else 0x7F800000
        expected_rsq = 0x7FC00000 if sign else 0x00000000
        if exp != expected_exp:
            errors.append(f"exp(Inf {inp:08x})={exp:08x}, expected {expected_exp:08x}")
        if rsqrt != expected_rsq:
            errors.append(f"rsqrt(Inf {inp:08x})={rsqrt:08x}, expected {expected_rsq:08x}")
    if exponent == 0:
        expected_exp = 0x3F800000
        expected_sin = 0x80000000 if sign else 0x00000000
        expected_cos = 0x3F800000
        expected_rsq = 0xFF800000 if sign else 0x7F800000
        for name, got, expected in (
            ("exp", exp, expected_exp),
            ("sin", sin, expected_sin),
            ("cos", cos, expected_cos),
            ("rsqrt", rsqrt, expected_rsq),
        ):
            if got != expected:
                errors.append(f"{name}(DAZ {inp:08x})={got:08x}, expected {expected:08x}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("golden", type=Path)
    args = parser.parse_args()

    records = []
    for line_no, raw in enumerate(args.golden.read_text(encoding="ascii").splitlines(), 1):
        match = LINE_RE.match(raw)
        if not match:
            print(f"FAIL malformed golden line {line_no}: {raw}", file=sys.stderr)
            return 1
        records.append(tuple(int(value, 16) for value in match.groups()))
    if len(records) != 9500:
        print(f"FAIL expected 9500 records, got {len(records)}", file=sys.stderr)
        return 1

    maxima = {"exp": (0.0, 0), "sin": (0.0, 0), "cos": (0.0, 0), "rsqrt": (0.0, 0)}
    counts = {name: 0 for name in maxima}
    errors = []

    for inp, exp_bits, sin_bits, rsq_bits, cos_bits in records:
        errors.extend(check_special(inp, exp_bits, sin_bits, rsq_bits, cos_bits))
        x = bits_to_float(inp)
        exponent = (inp >> 23) & 0xFF

        if exponent not in (0, 0xFF) and -80.0 <= x <= 80.0:
            got = bits_to_float(exp_bits)
            ref = math.exp(x)
            rel = abs(got - ref) / ref
            counts["exp"] += 1
            if rel > maxima["exp"][0]:
                maxima["exp"] = (rel, inp)

        if exponent != 0xFF and abs(x) < 131072.0:
            for name, bits, ref in (("sin", sin_bits, math.sin(x)), ("cos", cos_bits, math.cos(x))):
                err = abs(bits_to_float(bits) - ref)
                counts[name] += 1
                if err > maxima[name][0]:
                    maxima[name] = (err, inp)

        if (inp >> 31) == 0 and exponent not in (0, 0xFF):
            got = bits_to_float(rsq_bits)
            ref = 1.0 / math.sqrt(x)
            rel = abs(got - ref) / ref
            counts["rsqrt"] += 1
            if rel > maxima["rsqrt"][0]:
                maxima["rsqrt"] = (rel, inp)

    limits = {"exp": 4.0e-4, "sin": 1.6e-3, "cos": 1.6e-3, "rsqrt": 5.0e-4}
    for name in ("exp", "sin", "cos", "rsqrt"):
        value, inp = maxima[name]
        print(f"{name:6s} samples={counts[name]:4d} max_error={value:.9e} input={inp:08x}")
        if value >= limits[name]:
            errors.append(f"{name} max error {value:.9e} >= {limits[name]:.9e}")

    if errors:
        for error in errors[:40]:
            print(f"FAIL {error}", file=sys.stderr)
        if len(errors) > 40:
            print(f"FAIL ... and {len(errors) - 40} more", file=sys.stderr)
        return 1

    print("PASS independent SFU math/special-value verification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
