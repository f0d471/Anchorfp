#!/usr/bin/env bash
# 结构检查：每个模块单独交给 verilator，判据是没有 %Error
#   用法：bash lint.sh；全绿返回 0，任一模块有 Error 返回 1
#   保留的一条警告：fp32_mac_unit.v 的 lz_pos 拼接短于目标线宽，由零扩展补齐；
#   直接拼成目标宽度在部分参数下会出现非法的 0 宽度填充
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTL="$(cd "$HERE/../rtl" && pwd)"
COMMON="$(cd "$HERE/../../common" && pwd)"
VL=${VERILATOR:-verilator}
BAD=0

check() {                      # check <顶层> <源文件...>
    local top=$1; shift
    local out
    printf "  %-18s " "$top"
    out=$("$VL" --lint-only -Wno-fatal -I"$RTL" -I"$COMMON" --top-module "$top" "$@" 2>&1)
    local e w
    e=$(printf '%s\n' "$out" | grep -c '^%Error')
    w=$(printf '%s\n' "$out" | grep -c '^%Warning')
    if [ "$e" -ne 0 ]; then
        echo "FAIL: $e Error / $w Warning"
        printf '%s\n' "$out" | grep '^%Error' | head -3
        BAD=$((BAD + 1))
    else
        echo "PASS (Warning $w)"
    fi
}

echo "==== Anchorfp fp lint：$($VL --version 2>/dev/null) ===="
check fp32_add       "$RTL/fp32_add.v"
check fp32_mul_pipe  "$RTL/fp32_mul_pipe.v"
check fp32_cmp       "$RTL/fp32_cmp.v"
check fp32_cvt       "$RTL/fp32_cvt.v"
check fp32_recip     "$RTL/fp32_recip.v" "$COMMON/bram_lut_1024x32.v"
check fp32_mac_unit  "$RTL/fp32_mac_unit.v" "$RTL/fp32_mul_pipe.v"
check fp32_fpu_top   "$RTL/fp32_fpu_top.v" "$RTL/fp32_add.v" "$RTL/fp32_mul_pipe.v" \
                     "$RTL/fp32_cmp.v" "$RTL/fp32_cvt.v" "$RTL/fp32_recip.v" \
                     "$COMMON/bram_lut_1024x32.v"

if [ "$BAD" -eq 0 ]; then
    echo "  ALL PASS"
else
    echo "  $BAD 个模块有 Error"
    exit 1
fi
