#!/usr/bin/env bash
# omen-fan-curve —— 按 CPU/GPU 温度自动调节 hp-wmi 风扇 PWM
#
#   sudo ./fanctl.sh status            查看当前转速/PWM/温度
#   sudo ./fanctl.sh auto              交回 EC 自动控制（pwm1_enable=2）
#   sudo ./fanctl.sh manual 180        固定 PWM（0-255）
#   sudo ./fanctl.sh curve --dry-run   只计算目标值，不写硬件
#   sudo ./fanctl.sh daemon            常驻：每 5 秒按曲线调一次
#
# 曲线（温度 -> PWM）：45C:100  55C:130  65C:170  75C:210  85C:255
# 取 CPU 封装温度与 GPU 温度的较大值；>93C 强制满转，>97C 交回 EC 自救。
set -u

HPMON=""
for h in /sys/class/hwmon/hwmon*; do
    if [ "$(cat "$h/name" 2>/dev/null)" = "hp" ]; then HPMON="$h"; break; fi
done
[ -n "$HPMON" ] || { echo "找不到 hp hwmon（hp_wmi 未加载？）"; exit 1; }

PWM="$HPMON/pwm1"
EN="$HPMON/pwm1_enable"
INTERVAL="${INTERVAL:-5}"

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root：sudo $0 $*"; exit 1; }; }

cpu_temp() {
    local t=""
    for z in /sys/class/thermal/thermal_zone*; do
        case "$(cat "$z/type" 2>/dev/null)" in
            x86_pkg_temp|TCPU) t="${t} $(( $(cat "$z/temp" 2>/dev/null || echo 0)/1000 ))" ;;
        esac
    done
    if [ -z "${t// /}" ]; then
        for h in /sys/class/hwmon/hwmon*; do
            [ "$(cat "$h/name" 2>/dev/null)" = "coretemp" ] || continue
            for f in "$h"/temp*_input; do t="$t $(( $(cat "$f" 2>/dev/null || echo 0)/1000 ))"; done
        done
    fi
    echo "$t" | tr ' ' '\n' | sort -n | tail -1
}

gpu_temp() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    local v
    v=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
    [ -n "$v" ] && echo "$v" || return 1
}

# 分段线性插值
curve() {
    local t=$1
    awk -v t="$t" 'BEGIN{
        split("45 55 65 75 85", T); split("100 130 170 210 255", P);
        if (t <= T[1]) { print P[1]; exit }
        for (i=1;i<5;i++) if (t <= T[i+1]) {
            printf "%d\n", P[i] + (P[i+1]-P[i])*(t-T[i])/(T[i+1]-T[i]); exit
        }
        print P[5]
    }'
}

target() {
    local c g m
    c=$(cpu_temp); c=${c:-0}
    g=$(gpu_temp 2>/dev/null || echo "")
    m=$c
    if [ -n "$g" ] && [ "$g" -gt "$m" ]; then m=$g; fi
    if [ "$m" -ge 97 ]; then echo "AUTO"; return; fi
    if [ "$m" -ge 93 ]; then echo 255; return; fi
    curve "$m"
}

status() {
    printf '%-16s %s\n' "hwmon" "$HPMON"
    printf '%-16s %s\n' "CPU 温度" "$(cpu_temp)C"
    printf '%-16s %s\n' "GPU 温度" "$(gpu_temp 2>/dev/null || echo 'N/A')C"
    printf '%-16s %s\n' "风扇1/2" "$(cat "$HPMON/fan1_input" 2>/dev/null)/$(cat "$HPMON/fan2_input" 2>/dev/null) RPM"
    printf '%-16s %s (%s%%)\n' "PWM" "$(cat "$PWM" 2>/dev/null)" "$(awk -v x="$(cat "$PWM" 2>/dev/null || echo 0)" 'BEGIN{printf "%.0f", x*100/255}')"
    printf '%-16s %s%s\n' "模式" "$(cat "$EN" 2>/dev/null)" "$([ "$(cat "$EN" 2>/dev/null)" = 2 ] && echo ' (EC 自动)' || echo ' (手动)')"
}

apply() { # $1 = pwm | AUTO
    need_root
    if [ "$1" = "AUTO" ]; then
        printf '2\n' > "$EN"
        echo "$(date '+%F %T') 温度过高，交回 EC 自动控制"
        return
    fi
    if [ "$(cat "$EN" 2>/dev/null)" != "1" ]; then printf '1\n' > "$EN"; fi
    printf '%s\n' "$1" > "$PWM"
}

daemon() {
    need_root daemon
    echo "fan-curve 启动：每 ${INTERVAL}s 调整一次，Ctrl-C 退出并恢复 EC 自动"
    trap 'printf "2\n" > "$EN"; echo; echo "已恢复 EC 自动控制"; exit 0' INT TERM
    local last=-1 t
    while :; do
        t=$(target)
        if [ "$t" = "AUTO" ]; then apply AUTO; exit 0; fi
        if [ "$t" -ne "$last" ]; then
            apply "$t" && last=$t
            echo "$(date '+%T') cpu=$(cpu_temp)C gpu=$(gpu_temp 2>/dev/null || echo -)C -> pwm=$t fan=$(cat "$HPMON/fan1_input" 2>/dev/null)rpm"
        fi
        sleep "$INTERVAL"
    done
}

case "${1:-status}" in
    status) status ;;
    auto)   apply AUTO; status ;;
    manual) need_root manual; [ -n "${2:-}" ] || { echo "用法: sudo $0 manual <0-255>"; exit 2; }
            printf '1\n' > "$EN"; printf '%s\n' "$2" > "$PWM"; status ;;
    curve)  if [ "${2:-}" = "--dry-run" ]; then
                echo "CPU=$(cpu_temp)C GPU=$(gpu_temp 2>/dev/null || echo -)C 目标 PWM=$(target)"
            else apply "$(target)"; status; fi ;;
    daemon) daemon ;;
    *) echo "用法: $0 {status|auto|manual <pwm>|curve [--dry-run]|daemon}"; exit 2 ;;
esac
