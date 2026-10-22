#!/usr/bin/env bash
# 安装用户态工具到 /usr/local/sbin（内核模块与 nvidia-powerd 另行处理）
#
#   sudo ./install.sh              # 装脚本 + D-Bus 策略，不启用风扇服务
#   sudo ./install.sh --with-fan   # 同时启用风扇温度曲线服务
#   sudo ./install.sh --uninstall  # 移除本工具安装的内容
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/usr/local/sbin
UNIT=/etc/systemd/system/omen-fan-curve.service
DBUS=/usr/share/dbus-1/system.d/nvidia-powerd.conf
SCRIPTS=(status fanctl pl persist gpu-test)

log() { printf '==> %s\n' "$*"; }
need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root：sudo $0" >&2; exit 1; }; }

install_all() {
    need_root
    log "安装脚本到 $PREFIX"
    install -d "$PREFIX"
    for s in "${SCRIPTS[@]}"; do
        install -m 755 "$SRC/$s.sh" "$PREFIX/$s"
    done
    install -m 755 "$SRC/fanctl.sh" "$PREFIX/omen-fan-curve"

    log "安装 D-Bus 策略到 $DBUS"
    install -m 644 "$SRC/nvidia-powerd.conf" "$DBUS"
    chmod 644 "$DBUS"   # dbus-daemon 以 messagebus 用户读取，必须 644

    log "安装 systemd 单元"
    install -m 644 "$SRC/omen-fan-curve.service" "$UNIT"
    systemctl daemon-reload

    if [ "${WITH_FAN:-0}" = 1 ]; then
        log "启用风扇曲线服务"
        systemctl enable --now omen-fan-curve.service
    fi

    cat <<'EOF'

完成。脚本已安装为：
  status  fanctl  pl  persist  gpu-test  omen-fan-curve

后续（需要先编译内核模块）：
  sudo OMEN_KO=/path/to/omen_wmi_boost.ko persist install
  sudo systemctl enable --now nvidia-powerd

启用风扇曲线：
  sudo systemctl enable --now omen-fan-curve
EOF
}

uninstall_all() {
    need_root
    log "停止并移除风扇曲线服务"
    systemctl disable --now omen-fan-curve.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload

    log "移除脚本"
    for s in "${SCRIPTS[@]}"; do rm -f "$PREFIX/$s"; done
    rm -f "$PREFIX/omen-fan-curve"

    log "保留 $DBUS（nvidia-powerd 仍需要它）；如需删除请手动 rm"
}

WITH_FAN=0
case "${1:-}" in
    --with-fan)  WITH_FAN=1; install_all ;;
    --uninstall) uninstall_all ;;
    "")          install_all ;;
    *) echo "用法: $0 [--with-fan|--uninstall]" >&2; exit 2 ;;
esac
