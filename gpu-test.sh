#!/usr/bin/env bash
# 分阶段测试 omen_wmi_boost —— 不做持久化安装，随时可 off 撤销
#
#   sudo ./gpu-test.sh probe     # 只读：读 GC21 当前 CTGP/DTGP、系统设计数据
#   sudo ./gpu-test.sh enable    # 只写 0x22：CTGP=1 DTGP=1（最保守的解锁）
#   sudo ./gpu-test.sh perf      # 先设热档位 0x31，再解锁（若 enable 无效再试）
#   sudo ./gpu-test.sh status    # 看状态，不加载/不修改
#   sudo ./gpu-test.sh off       # 卸载模块（会自动写回 CTGP=0 DTGP=0）
set -u

# 内核模块 .ko 的位置：可用 OMEN_KO 覆盖，否则在常见路径里找
KO="${OMEN_KO:-}"
if [ -z "$KO" ]; then
    for c in \
        "$HOME/5080-Unlock_Linux/omen_wmi_boost/omen_wmi_boost.ko" \
        "/usr/src/omen_wmi_boost/omen_wmi_boost.ko" \
        "./omen_wmi_boost.ko"; do
        [ -f "$c" ] && { KO="$c"; break; }
    done
fi
MOD=omen_wmi_boost
SYS=/sys/kernel/omen_wmi_boost

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $1"; exit 1; }; }

precheck() {
    [ -f "$KO" ] || { echo "找不到 $KO，先编译：make -C $(dirname $KO)"; exit 1; }
    board=$(cat /sys/class/dmi/id/board_name 2>/dev/null)
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    echo "board=$board product=$product"
    [ "$board" = "8D41" ] || echo "警告：不是 8D41，请自行确认"
}

unload() {
    if [ -d "/sys/module/$MOD" ]; then
        modprobe -r "$MOD" 2>/dev/null || rmmod "$MOD" 2>/dev/null
        sleep 1
    fi
}

load_with() {
    unload
    echo "== insmod $* =="
    if ! insmod "$KO" force_unsupported=1 persist=1 "$@"; then
        echo "insmod 失败，最近内核日志："
        dmesg | tail -20
        exit 1
    fi
    sleep 2
    echo
    echo "== dmesg =="
    dmesg | tail -25 | grep -E "omen_wmi_boost|omen|WMI|CTGP|DTGP|thermal|firmware" || dmesg | tail -15
    echo
    echo "== sysfs =="
    for f in gpu_state last_error thermal_profile fan_state; do
        [ -r "$SYS/$f" ] && printf '  %-16s %s\n' "$f" "$(tr '\n' ' ' < "$SYS/$f")"
    done
    echo
    echo "== nvidia-smi =="
    nvidia-smi -q -d POWER 2>/dev/null | awk -F': *' '
        /Current Power Limit/ && !c++ {print "  当前功耗墙 " $2}
        /Requested Power Limit/ && !r++ {print "  请求功耗墙 " $2}
        /Max Power Limit/ && !m++ {print "  硬件上限   " $2}'
    nvidia-smi --query-gpu=power.draw,temperature.gpu --format=csv,noheader 2>/dev/null | sed 's/^/  现在: /'
}

status() {
    echo "== 模块 =="
    if [ -d "/sys/module/$MOD" ]; then echo "已加载 $(cat /sys/module/$MOD/version 2>/dev/null)"; else echo "未加载"; fi
    [ -r "$SYS/gpu_state" ] && echo "gpu_state: $(cat "$SYS/gpu_state")"
    [ -r "$SYS/last_error" ] && echo "last_error: $(cat "$SYS/last_error")"
    echo "== GPU =="
    nvidia-smi -q -d POWER 2>/dev/null | awk -F': *' '
        /Current Power Limit/ && !c++ {print "  当前功耗墙 " $2}
        /Requested Power Limit/ && !r++ {print "  请求功耗墙 " $2}
        /Max Power Limit/ && !m++ {print "  硬件上限   " $2}'
    echo "== powerd =="
    systemctl is-active nvidia-powerd 2>&1 | sed 's/^/  /'
}

case "${1:-status}" in
    probe)   need_root probe;   precheck; load_with boot_mode=trace ;;
    enable)  need_root enable;  precheck; load_with boot_mode=enable ;;
    perf)    need_root perf;    precheck; load_with boot_mode=performance thermal_profile=0x31 ;;
    off)     need_root off;     unload; echo "已卸载（CTGP/DTGP 已写回 0）"; status ;;
    status)  status ;;
    *) echo "用法: $0 {probe|enable|perf|status|off}"; exit 2 ;;
esac
