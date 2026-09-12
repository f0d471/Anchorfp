#!/usr/bin/env bash
# 结构检查：每个模块单独交给 verilator，判据是没有 %Error
#   用法：bash lint.sh；全绿返回 0，任一模块有 Error 返回 1
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

echo "==== Anchorfp sfu lint：$($VL --version 2>/dev/null) ===="
check bram_lut_1024x32  "$COMMON/bram_lut_1024x32.v"
check trig_phase_reduce "$RTL/trig_phase_reduce.v"
check sincos_func       "$RTL/sincos_func.v" "$RTL/trig_phase_reduce.v"
check sin_func          "$RTL/sin_func.v" "$RTL/sincos_func.v" "$RTL/trig_phase_reduce.v"
check cos_func          "$RTL/cos_func.v" "$RTL/sincos_func.v" "$RTL/trig_phase_reduce.v"
check exp_func          "$RTL/exp_func.v" "$COMMON/bram_lut_1024x32.v"
check rsqrt_func        "$RTL/rsqrt_func.v" "$COMMON/bram_lut_1024x32.v"

if [ "$BAD" -eq 0 ]; then
    echo "  ALL PASS"
else
    echo "  $BAD 个模块有 Error"
    exit 1
fi
