#!/usr/bin/env bash
# 持久化 omen_wmi_boost（最小方案：只装内核模块 + modprobe/modules-load 配置）
#
#   sudo ./persist.sh install   # 安装模块与开机配置
#   sudo ./persist.sh status    # 查看是否已持久化
#   sudo ./persist.sh remove    # 卸载（会先写回 CTGP=0 DTGP=0）
#
# 说明：
#  * 不带仓库的 omen-wmi-*-verify / fan-control / usb-s5 服务；
#    关机 disarm 由模块内置的 reboot notifier 完成。
#  * boot_mode=enable 只写 WMI 0x22（CTGP/DTGP=1），不碰热档位 0x1a。
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
KVER="$(uname -r)"
DST="/lib/modules/${KVER}/extra"
MOD=omen_wmi_boost
CONF_LOAD=/etc/modules-load.d/omen_wmi_boost.conf
CONF_OPT=/etc/modprobe.d/omen_wmi_boost.conf

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $1"; exit 1; }; }

install_it() {
    need_root install
    [ -f "$KO" ] || { echo "找不到 $KO，请先 make -C $(dirname "$KO")"; exit 1; }
    echo "== 安装模块到 $DST =="
    install -D -m 644 "$KO" "$DST/omen_wmi_boost.ko"
    depmod -a "$KVER"
    printf '%s\n' "$MOD" > "$CONF_LOAD"
    cat > "$CONF_OPT" <<'EOF'
# OMEN MAX 16-ah0xxx (board 8D41) — 非验证板型，需 force_unsupported
# persist=1 提供 sysfs 与关机 disarm；boot_mode=enable 只解锁 CTGP/DTGP
options omen_wmi_boost force_unsupported=1 persist=1 auto_boost=0 boot_mode=enable
EOF
    chmod 644 "$CONF_LOAD" "$CONF_OPT"
    echo "  $CONF_LOAD: $(cat "$CONF_LOAD")"
    echo "  $CONF_OPT: $(grep '^options' "$CONF_OPT")"
    echo
    echo "== 校验 modinfo =="
    modinfo -k "$KVER" "$MOD" | grep -E 'filename|version|vermagic'
    echo
    echo "== 用新配置重新加载 =="
    modprobe -r "$MOD" 2>/dev/null || true
    if modprobe "$MOD"; then
        sleep 1
        echo "  gpu_state: $(cat /sys/kernel/${MOD}/gpu_state 2>/dev/null)"
    else
        echo "  modprobe 失败，看 dmesg："; dmesg | tail -10
        exit 1
    fi
    echo
    echo "完成。重启后由 modules-load.d 自动加载。"
}

status_it() {
    echo "== 文件 =="
    for f in "$DST/omen_wmi_boost.ko" "$CONF_LOAD" "$CONF_OPT"; do
        [ -e "$f" ] && printf '  present  %s\n' "$f" || printf '  absent   %s\n' "$f"
    done
    echo "== 运行态 =="
    printf '  module: %s\n' "$([ -d /sys/module/$MOD ] && echo loaded || echo 'not loaded')"
    printf '  gpu_state: %s\n' "$(cat /sys/kernel/$MOD/gpu_state 2>/dev/null || echo '-')"
    printf '  powerd: %s\n' "$(systemctl is-active nvidia-powerd 2>&1)"
    printf '  dbus 策略: %s\n' "$([ -e /usr/share/dbus-1/system.d/nvidia-powerd.conf ] && echo present || echo missing)"
    nvidia-smi -q -d POWER 2>/dev/null | awk -F': *' '/Current Power Limit/ && !c++ {print "  GPU 当前墙: " $2}'
}

remove_it() {
    need_root remove
    echo "== 卸载前先 disarm =="
    if [ -w /sys/kernel/$MOD/boost ]; then echo 0 > /sys/kernel/$MOD/boost || true; sleep 1; fi
    modprobe -r "$MOD" 2>/dev/null || rmmod "$MOD" 2>/dev/null || true
    rm -f "$CONF_LOAD" "$CONF_OPT" "$DST/omen_wmi_boost.ko"
    depmod -a "$KVER"
    echo "已移除开机配置与模块（nvidia-powerd 与 dbus 策略未动）。"
}

case "${1:-status}" in
    install) install_it ;;
    status)  status_it ;;
    remove)  remove_it ;;
    *) echo "用法: $0 {install|status|remove}"; exit 2 ;;
esac
