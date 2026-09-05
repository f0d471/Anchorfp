#!/usr/bin/env python3
"""扫出「复位被综合成时钟使能」的写法。

模式：

    always @(posedge clk) begin
        if (!rst_n) begin
            a <= 0;              // 复位分支只赋很少几个
        end else begin
            a <= ...;
            b <= ...;            // else 分支赋一大堆
            c <= ...;
        end
    end

只在复位分支出现的信号，复位期间保持不变，而「保持不变」正是时钟使能的语义。
综合器会把 rst_n 接成 b、c 这些寄存器的 CE，于是复位网扇出到成百上千个 CE 端，
形成一条零级逻辑、纯布线的高扇出路径。

2026-09-06 在 fp32_mac_unit 的 Na/Nb 两级实测到这个形态：整机布线后最差
setup 路径就是它，levels=0，终点是 n1_mag_reg 的 CE 脚。修法是把控制位与
数据位拆成两个 always，数据位无条件更新。

用法：python3 tools/scan_reset_as_ce.py [rtl 根目录，默认 rtl]

报出来的不一定都要改：数据位真的需要复位值时，接复位是对的。
这个脚本只负责把「只有个别信号有复位值、其余十几个没有」的地方找出来，
是否要改由人看。阈值定得保守，宁可漏报也不刷屏。
"""

import io
import re
import sys
from pathlib import Path

# 至少这么多个信号只出现在 else 分支，才值得报
MIN_CE_SIGS = 4

ALWAYS = re.compile(r'always\s*@\s*\(\s*posedge\b')
ASSIGN = re.compile(r'^\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*<=')


def blocks(text):
    """切出每个 always @(posedge ...) 块，按括号配平。返回 (起始行号, 文本)。"""
    out = []
    for m in ALWAYS.finditer(text):
        i = m.start()
        depth, j, started = 0, i, False
        while j < len(text):
            if text.startswith('begin', j) and not text[j-1:j].isalnum():
                depth += 1
                started = True
                j += 5
                continue
            if text.startswith('end', j) and not text[j-1:j].isalnum() \
                    and not text.startswith('endmodule', j):
                depth -= 1
                j += 3
                if started and depth <= 0:
                    break
                continue
            j += 1
        out.append((text[:i].count('\n') + 1, text[i:j]))
    return out


def split_reset(body):
    """粗切复位分支与 else 分支。找第一个 if (!rst_n) 与配对的 else。"""
    m = re.search(r'if\s*\(\s*!\s*(\w*rst\w*|\w*reset\w*)\s*\)', body)
    if not m:
        return None, None
    rest = body[m.end():]
    me = re.search(r'\belse\b', rest)
    if not me:
        return None, None
    return rest[:me.start()], rest[me.end():]


def sigs(chunk):
    return {a.group(1) for a in (ASSIGN.match(l) for l in chunk.split('\n')) if a}


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else 'rtl')
    hits = 0
    for p in sorted(root.rglob('*')):
        if p.suffix not in ('.v', '.sv') or 'PLL_' in str(p):
            continue
        text = io.open(p, encoding='utf-8', errors='replace').read()
        for line0, body in blocks(text):
            rb, eb = split_reset(body)
            if rb is None:
                continue
            r, e = sigs(rb), sigs(eb)
            ce = e - r
            if len(r) and len(ce) >= MIN_CE_SIGS:
                hits += 1
                print('%s:%d  复位分支 %d 个 %s；只在 else 分支 %d 个：%s'
                      % (p, line0, len(r), sorted(r), len(ce),
                         ', '.join(sorted(ce)[:10])))
    print('SUMMARY scan_reset_as_ce: %d 处待看（阈值 else 独有信号 >= %d）'
          % (hits, MIN_CE_SIGS))
    return 0


if __name__ == '__main__':
    sys.exit(main())
