#!/usr/bin/env bash
# CPU 功耗墙 (RAPL) 设置/查看工具
#   sudo ./pl.sh status        # 查看当前 PL1/PL2（MSR 与 MMIO 两套读数）
#   sudo ./pl.sh 120           # 设 PL1=PL2=120W 并校验回读
#   sudo ./pl.sh 120 140       # 分别设 PL1=120W、PL2=140W
#   sudo ./pl.sh reset         # 恢复 PL1=PL2=170W
set -u

DOM=/sys/class/powercap/intel-rapl:0
MMIO=/sys/class/powercap/intel-rapl-mmio:0
UW=1000000

w() { awk -v v="${1:-0}" 'BEGIN{printf "%.0f", v/1000000}'; }
rd() { cat "$1" 2>/dev/null || echo "-"; }

status() {
    printf '%-10s %-10s %s\n' "接口" "PL1" "PL2"
    printf '%-10s %-10s %s\n' "MSR" "$(w "$(rd $DOM/constraint_0_power_limit_uw)")W" "$(w "$(rd $DOM/constraint_1_power_limit_uw)")W"
    [ -d "$MMIO" ] && printf '%-10s %-10s %s\n' "MMIO" "$(w "$(rd $MMIO/constraint_0_power_limit_uw)")W" "$(w "$(rd $MMIO/constraint_1_power_limit_uw)")W"
    printf '%-10s %s\n' "档位" "$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
    printf '%-10s %s\n' "EPP" "$(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null)"
    printf '%-10s %s\n' "no_turbo" "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
}

set_one() { # $1=cpu, $2=value_uw
    local f="$DOM/constraint_$1_power_limit_uw"
    local want="$2" before after err
    before=$(rd "$f")
    err=$(printf '%s\n' "$want" > "$f" 2>&1) || {
        printf 'PL%s 写入失败: %s\n' "$((1+$1))" "${err:-permission denied}"
        return 1
    }
    after=$(rd "$f")
    if [ "$after" = "$want" ]; then
        printf 'PL%s: %sW -> %sW  (OK)\n' "$((1+$1))" "$(w "$before")" "$(w "$after")"
    else
        printf 'PL%s: 写入 %sW 但回读 %sW（被拒/被覆盖）\n' "$((1+$1))" "$(w "$want")" "$(w "$after")"
        return 2
    fi
}

case "${1:-status}" in
    status) status ;;
    reset)  set_one 0 $((170*UW)); set_one 1 $((170*UW)) ;;
    *)
        p1="$1"; p2="${2:-$1}"
        case "$p1" in ''|*[!0-9]*) echo "用法: sudo $0 <PL1瓦数> [PL2瓦数] | status | reset"; exit 2;; esac
        case "$p2" in ''|*[!0-9]*) echo "PL2 必须是数字"; exit 2;; esac
        echo "== 写入前 =="; status
        echo
        rc=0
        set_one 0 $((p1*UW)) || rc=1
        set_one 1 $((p2*UW)) || rc=1
        echo; echo "== 写入后 =="; status
        echo
        echo "提示: MMIO 侧可能不跟随（两套接口），以 MSR 侧和实际 PkgWatt 为准。"
        exit "$rc"
        ;;
esac
