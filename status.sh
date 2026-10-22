#!/usr/bin/env bash
# OMEN MAX 16 (8D41) 风扇 / 温度 / 功耗墙 只读巡检
# 用法: ./status.sh        （不需要 root；少数项目 root 才能读，会标注）
set -u

HPMON=""
for h in /sys/class/hwmon/hwmon*; do
    if [ "$(cat "$h/name" 2>/dev/null)" = "hp" ]; then HPMON="$h"; break; fi
done

hr() { printf '%s\n' "------------------------------------------------------------"; }
w()  { awk -v v="$1" 'BEGIN{printf "%.1f", v/1000000}'; }
c()  { awk -v v="$1" 'BEGIN{printf "%.1f", v/1000}'; }

echo "=== 机器 ==="
printf '%-12s %s\n' "机型"   "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
printf '%-12s %s\n' "主板"   "$(cat /sys/class/dmi/id/board_name 2>/dev/null)"
printf '%-12s %s\n' "BIOS"   "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
printf '%-12s %s\n' "内核"   "$(uname -r)"
_ac=$(cat /sys/class/power_supply/AC/online 2>/dev/null)
case "${_ac:-x}" in 1) _ac="AC 已接";; 0) _ac="电池供电";; *) _ac="未知";; esac
printf '%-12s %s\n' "供电"   "$_ac"

hr
echo "=== 平台档位 ==="
printf '%-22s %s\n' "ppd ActiveProfile" "$(busctl --system get-property net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile 2>/dev/null | awk '{print $2}' | tr -d '"')"
printf '%-22s %s\n' "platform_profile"  "$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
printf '%-22s %s\n' "可选"              "$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
printf '%-22s %s\n' "ActiveProfileHolds" "$(busctl --system get-property net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfileHolds 2>/dev/null)"

hr
echo "=== CPU 功耗墙 (RAPL) ==="
for dom in /sys/class/powercap/intel-rapl:0; do
    [ -d "$dom" ] || continue
    for i in 0 1 2; do
        lim="$dom/constraint_${i}_power_limit_uw"
        [ -e "$lim" ] || continue
        printf '%-28s %8s W   (max %s W, window %s us)\n' \
            "$(cat "$dom/constraint_${i}_name" 2>/dev/null) PL$((i+1))" \
            "$(w "$(cat "$lim")")" \
            "$(w "$(cat "$dom/constraint_${i}_max_power_uw" 2>/dev/null || echo 0)")" \
            "$(cat "$dom/constraint_${i}_time_window_us" 2>/dev/null || echo -)"
    done
done
printf '%-28s %s\n' "intel_pstate no_turbo" "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
printf '%-28s %s\n' "governor(CPU0)"      "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)"
printf '%-28s %s\n' "EPP(CPU0)"           "$(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null)"
printf '%-28s %s\n' "max_freq(CPU0)"      "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null) kHz"
printf '%-28s pkg=%s core=%s\n' "限频计数" \
    "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count 2>/dev/null)" \
    "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null)"

hr
echo "=== 风扇 ==="
if [ -n "$HPMON" ]; then
    printf '%-12s %s\n' "hwmon" "$HPMON"
    for f in fan1_input fan2_input pwm1 pwm1_enable; do
        v=$(cat "$HPMON/$f" 2>/dev/null || echo "-")
        case $f in
            fan*_input) printf '%-12s %s RPM\n' "$f" "$v" ;;
            pwm1)       printf '%-12s %s / 255 (%s%%)\n' "$f" "$v" "$(awk -v x="$v" 'BEGIN{printf "%.0f", x*100/255}')" ;;
            *)          printf '%-12s %s%s\n' "$f" "$v" "$([ "$f" = pwm1_enable ] && echo '  (0=全速 1=手动 2=自动/EC)')" ;;
        esac
    done
else
    echo "未找到 hp hwmon"
fi
for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat "$z/type" 2>/dev/null)
    case $t in TCPU|TCPU_PCI|x86_pkg_temp|acpitz)
        printf '%-12s %s C\n' "$t" "$(c "$(cat "$z/temp")")" ;;
    esac
done

hr
echo "=== GPU ==="
printf '%-22s %s\n' "型号" "$(grep -m1 '^Model:' /proc/driver/nvidia/gpus/*/information 2>/dev/null | sed 's/^Model:[[:space:]]*//')"
printf '%-22s %s\n' "驱动" "$(sed -n 's/^NVRM version: //p' /proc/driver/nvidia/version 2>/dev/null)"
if command -v nvidia-smi >/dev/null 2>&1; then
    if out=$(nvidia-smi -q -d POWER 2>&1); then
        echo "$out" | awk -F': *' '/Current Power Limit/   && !c++ {printf "  %-22s %s\n","当前功耗墙",$2}
                                         /Requested Power Limit/ && !r++ {printf "  %-22s %s\n","请求功耗墙",$2}
                                         /Max Power Limit/       && !m++ {printf "  %-22s %s\n","硬件上限",$2}'
        printf '%-22s %s\n' "实时功耗/温度" "$(nvidia-smi --query-gpu=power.draw,temperature.gpu --format=csv,noheader 2>/dev/null)"
    else
        echo "  nvidia-smi 不可用: $(echo "$out" | head -1)"
    fi
fi
printf '%-22s %s\n' "nvidia-powerd" "$(systemctl is-active nvidia-powerd 2>&1)"
[ -e /sys/kernel/omen_wmi_boost/gpu_state ] && printf '%-22s %s\n' "omen_wmi_boost" "$(cat /sys/kernel/omen_wmi_boost/gpu_state 2>/dev/null)" || printf '%-22s %s\n' "omen_wmi_boost" "未安装"

hr
echo "=== 关键内核提示 ==="
journalctl -k -b --no-pager 2>/dev/null | grep -iE 'hp_wmi|hp-wmi' | tail -5
