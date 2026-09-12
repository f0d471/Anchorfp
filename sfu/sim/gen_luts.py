#!/usr/bin/env python3
"""SFU 四张 FP32 查找表的生成器与校验器，表的取样口径以本文件为准。

用法：
  python3 gen_luts.py --write   # 重建 rtl/ 下的四张表与两份 manifest
  python3 gen_luts.py --check   # 不写文件，任一缺失或内容不符返回非零

表项先按 binary64 求值，再按 IEEE-754 就近舍入收成 FP32 位图；
文本为小写 8 位十六进制、LF 换行，重复运行结果逐字节相同。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path


COUNT = 1024
ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = ROOT / "rtl"
JSON_MANIFEST = RTL_DIR / "sfu_lut_manifest.json"
TCL_MANIFEST = RTL_DIR / "sfu_lut_manifest.tcl"


def fp32_bits(value: float) -> int:
    return struct.unpack(">I", struct.pack(">f", value))[0]


def build_tables() -> dict[str, list[int]]:
    # exp 按区间中点取样，截断索引的单边误差对半
    exp = [fp32_bits(2.0 ** ((i + 0.5) / COUNT)) for i in range(COUNT)]

    # sin 为四分之一周期闭区间表，首末项逐位为 0.0 与 1.0
    sin = [fp32_bits(math.sin((math.pi * 0.5) * i / (COUNT - 1))) for i in range(COUNT)]

    # rsqrt 以尾数高 10 位为地址，按区间左端点取样；奇数表含 1/sqrt(2) 因子
    rsqrt_even = [fp32_bits(1.0 / math.sqrt(1.0 + i / COUNT)) for i in range(COUNT)]
    rsqrt_odd = [fp32_bits(1.0 / math.sqrt(2.0 * (1.0 + i / COUNT))) for i in range(COUNT)]

    return {
        "exp_lut.mem": exp,
        "sin_lut.mem": sin,
        "rsqrt_even_lut.mem": rsqrt_even,
        "rsqrt_odd_lut.mem": rsqrt_odd,
    }


def table_bytes(values: list[int]) -> bytes:
    return "".join(f"{value:08x}\n" for value in values).encode("ascii")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_manifests(tables: dict[str, list[int]]) -> tuple[bytes, bytes]:
    entries = {}
    sampling = {
        "exp_lut.mem": "2^((i+0.5)/1024), midpoint",
        "sin_lut.mem": "sin((pi/2)*i/1023), closed interval",
        "rsqrt_even_lut.mem": "1/sqrt(1+i/1024), left endpoint",
        "rsqrt_odd_lut.mem": "1/sqrt(2*(1+i/1024)), left endpoint",
    }
    for name, values in tables.items():
        data = table_bytes(values)
        entries[name] = {
            "count": len(values),
            "first": f"{values[0]:08x}",
            "last": f"{values[-1]:08x}",
            "sampling": sampling[name],
            "sha256": sha256(data),
        }

    # 这里的误差只描述「一个表项覆盖一个地址区间」本身；
    # 定点化与相位归约带来的误差由 verify_sfu.py 对 RTL 输出另算
    exp_interval = 0.0
    even_interval = 0.0
    odd_interval = 0.0
    sin_interval = 0.0
    for i in range(COUNT):
        exp_y = struct.unpack(">f", struct.pack(">I", tables["exp_lut.mem"][i]))[0]
        exp_interval = max(
            exp_interval,
            abs(exp_y / (2.0 ** (i / COUNT)) - 1.0),
            abs(exp_y / (2.0 ** ((i + 1) / COUNT)) - 1.0),
        )

        right = 1.0 + (i + 1) / COUNT
        even_y = struct.unpack(">f", struct.pack(">I", tables["rsqrt_even_lut.mem"][i]))[0]
        odd_y = struct.unpack(">f", struct.pack(">I", tables["rsqrt_odd_lut.mem"][i]))[0]
        even_interval = max(even_interval, abs(even_y / (1.0 / math.sqrt(right)) - 1.0))
        odd_interval = max(odd_interval, abs(odd_y / (1.0 / math.sqrt(2.0 * right)) - 1.0))

        sin_y = struct.unpack(">f", struct.pack(">I", tables["sin_lut.mem"][i]))[0]
        left_phase = (math.pi * 0.5) * i / (COUNT - 1)
        right_phase = min(math.pi * 0.5, (math.pi * 0.5) * (i + 1) / (COUNT - 1))
        sin_interval = max(
            sin_interval,
            abs(sin_y - math.sin(left_phase)),
            abs(sin_y - math.sin(right_phase)),
        )

    entries["exp_lut.mem"]["interval_max_relative_error"] = f"{exp_interval:.12e}"
    entries["sin_lut.mem"]["interval_max_absolute_error"] = f"{sin_interval:.12e}"
    entries["rsqrt_even_lut.mem"]["interval_max_relative_error"] = f"{even_interval:.12e}"
    entries["rsqrt_odd_lut.mem"]["interval_max_relative_error"] = f"{odd_interval:.12e}"

    manifest = {
        "format": "lowercase 8-hex-digit FP32 words, LF newline",
        "generator": "gen_luts.py",
        "index_bits": 10,
        "rounding": "binary64 formula evaluation, then IEEE-754 FP32 round-to-nearest-even",
        "tables": entries,
        "version": 1,
    }
    json_data = (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")

    lines = [
        "# 由 gen_luts.py 生成，不要手改",
        "set sfu_lut_manifest [dict create \\",
    ]
    names = list(tables)
    for index, name in enumerate(names):
        entry = entries[name]
        suffix = " \\" if index != len(names) - 1 else ""
        lines.append(
            f'  "{name}" [dict create count {entry["count"]} '
            f'first "{entry["first"]}" last "{entry["last"]}" '
            f'sha256 "{entry["sha256"]}"]{suffix}'
        )
    lines.append("]")
    tcl_data = ("\n".join(lines) + "\n").encode("utf-8")
    return json_data, tcl_data


def expected_files() -> dict[Path, bytes]:
    tables = build_tables()
    files: dict[Path, bytes] = {}
    for name, values in tables.items():
        files[RTL_DIR / name] = table_bytes(values)
    json_data, tcl_data = build_manifests(tables)
    files[JSON_MANIFEST] = json_data
    files[TCL_MANIFEST] = tcl_data
    return files


def write_files(files: dict[Path, bytes]) -> None:
    for path, data in files.items():
        path.write_bytes(data)
        print(f"WRITE {path.relative_to(ROOT)}  sha256={sha256(data)}")


def check_files(files: dict[Path, bytes]) -> bool:
    ok = True
    for path, expected in files.items():
        rel = path.relative_to(ROOT)
        if not path.is_file():
            print(f"MISSING {rel}", file=sys.stderr)
            ok = False
            continue
        actual = path.read_bytes()
        if actual != expected:
            print(
                f"DRIFT {rel}: expected sha256={sha256(expected)}, actual sha256={sha256(actual)}",
                file=sys.stderr,
            )
            ok = False
        else:
            print(f"OK    {rel}  sha256={sha256(actual)}")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()

    files = expected_files()
    if args.write:
        write_files(files)
        return 0
    return 0 if check_files(files) else 1


if __name__ == "__main__":
    raise SystemExit(main())
