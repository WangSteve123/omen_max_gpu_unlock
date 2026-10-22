# OMEN MAX 16 Linux Power & Fan Toolkit

> 面向 HP OMEN MAX 16 系列（Intel 主板 `8D41`）的 Linux 调校工具集：
> 风扇温度曲线、CPU RAPL 功耗墙、NVIDIA TGP 解锁验证与开机持久化。
>
> A small userspace toolkit for HP OMEN MAX 16 laptops on Linux — fan curves via
> `hp-wmi`, CPU RAPL power limits, NVIDIA TGP unlock verification, and boot
> persistence for the third-party `omen_wmi_boost` kernel module.

---

## 特性

- **风扇曲线**：基于 `hp-wmi` 暴露的 `pwm1`（0–255），按 CPU/GPU 温度线性插值调速，支持自动/手动/常驻守护。
- **CPU 功耗墙**：直接读写 RAPL `PL1/PL2`，写入后自动回读校验。
- **GPU TGP 验证**：分阶段探测 `CTGP/DTGP` 解锁状态，问题定位到具体 WMI 步骤。
- **最小化持久化**：只安装内核模块与 `modprobe.d`/`modules-load.d` 配置，不引入上游的额外服务。
- **一键巡检**：单条命令输出平台档位、RAPL、`intel_pstate`、风扇、温度、GPU 限值与模块状态。
- **附带 D-Bus 策略**：修复 `nvidia-powerd` 因缺少 `nvidia.powerd.server` 策略而无法启动的问题。

不做的事：不超频、不修改 vBIOS、不接管 EC 固件策略（除非手动 PWM 模式）。

---

## 兼容性

| 项目 | 状态 |
|---|---|
| HP OMEN MAX 16-ah0xxx / 主板 `8D41`（Intel Core Ultra 9 275HX + RTX 5080 Laptop） | 已验证 |
| HP OMEN MAX 16-ak0xxx / 主板 `8D87`（AMD） | 上游模块已验证 |
| 其它带 `hp-wmi` hwmon 的 HP OMEN / Victus | 风扇与巡检部分可能可用，TGP 部分需自行验证 |
| Ubuntu 24.04 / 内核 7.0.0-38-generic | 已验证 |
| Secure Boot | 需关闭（模块未签名） |

---

## 依赖

- Linux 内核带 `hp-wmi`（风扇 PWM 与平台档位）
- `bash`、`python3`、`make`、`gcc`、内核头文件（`linux-headers-$(uname -r)`）
- NVIDIA 驱动与可用的 `nvidia-smi`
- （可选）`glmark2`、`hashcat` 等用于压测

---

## 安装

仓库通过 submodule 引入第三方内核模块源码（GPL-2.0，独立分发）：

```bash
git clone --recursive https://github.com/WangSteve123/omen_max_gpu_unlock.git
cd omen_max_gpu_unlock

# 已 clone 但未带 --recursive 时：
git submodule update --init --recursive
```

安装用户态工具（脚本进 `/usr/local/sbin`，并安装 D-Bus 策略与 systemd 单元）：

```bash
sudo ./install.sh --with-fan     # 不带 --with-fan 则只装脚本与单元，不启用风扇曲线
```

编译并持久化内核模块：

```bash
make -C external/5080-Unlock_Linux/omen_wmi_boost
sudo ./persist.sh install        # 装到 /lib/modules/$(uname -r)/extra 并配置开机加载
```

启用 NVIDIA 动态加速：

```bash
sudo cp /usr/share/doc/nvidia-kernel-common-595/nvidia-powerd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-powerd
```

重启后验证：

```bash
status
```

---

## 用法

安装后可直接使用以下命令（也可在仓库内以 `./xxx.sh` 运行）：

### `status` — 只读巡检

输出机型、平台档位、RAPL 功耗墙、`intel_pstate`、风扇转速/PWM、温度、GPU 限值与模块状态。

```bash
status
```

### `fanctl` — 风扇控制

```bash
sudo fanctl status             # 当前温度 / 转速 / PWM / 模式
sudo fanctl auto               # 交回 EC 固件自动控制
sudo fanctl manual 200         # 固定 PWM（0–255）
sudo fanctl curve --dry-run    # 只计算目标值，不写硬件
sudo fanctl daemon             # 常驻，按曲线调整
```

内置曲线（取 CPU 封装温度与 GPU 温度的较大值）：

| 温度 | 45 °C | 55 °C | 65 °C | 75 °C | 85 °C | ≥93 °C | ≥97 °C |
|---|---|---|---|---|---|---|---|
| PWM | 100 | 130 | 170 | 210 | 255 | 255 | 交回 EC |

### `pl` — CPU 功耗墙

```bash
pl status          # 查看 PL1/PL2（MSR 与 MMIO 两套读数）
sudo pl 120        # PL1 = PL2 = 120 W，写入后回读校验
sudo pl 120 140    # 分别设置 PL1 / PL2
sudo pl reset      # 恢复 170 W
```

> 部分机型的 `constraint_*_max_power_uw` 是固件上报的基础 TDP，只作参考；能否写入以回读结果为准。

### `gpu-test` — TGP 解锁验证

```bash
sudo gpu-test probe    # 只读：读取 CTGP/DTGP 当前状态
sudo gpu-test enable   # 只写 WMI 0x22（最小解锁动作）
sudo gpu-test perf     # 先设热档位 0x31，再解锁
sudo gpu-test off      # 卸载模块并写回 CTGP=0 DTGP=0
```

### `persist` — 模块持久化

```bash
sudo persist install   # 安装 .ko 到 extra/ 并写入开机配置
persist status         # 检查文件、模块、powerd、D-Bus 策略
sudo persist remove    # 卸载（先 disarm，再移除配置）
```

`.ko` 查找顺序：`OMEN_KO` 环境变量 → 本仓库 submodule → `~/5080-Unlock_Linux` → `/usr/src/omen_wmi_boost`。

---

## 工作原理

- **风扇**：内核 `hp-wmi` 以 hwmon 暴露单路 `pwm1`（0–255，双风扇联动）与 `pwm1_enable`（0=全速 / 1=手动 / 2=自动）。工具写入 `pwm1_enable=1` 后调节 `pwm1`；停止时恢复 `2`，交回 EC。手动值会被驱动的 keep-alive 周期性刷新，属正常现象。
- **CPU**：`intel_rapl_msr` 暴露 `constraint_0/1_power_limit_uw`（PL1/PL2）。写入即生效，但部分 HP 机型由 EC 固定功耗墙，平台档位切换不会改变 PL。
- **GPU**：`omen_wmi_boost` 通过 HP WMI 发送 `0x10`（EC 用户态触发）与 `0x22`（`CTGP/DTGP=1`），向固件申请更高的 TGP 预算；`nvidia-powerd` 再通过 Dynamic Boost 把上限从基础值抬到峰值。典型表现为 `80 W → 150 W 基础 / 175 W 峰值`，并随负载浮动。

---

## 配置

**风扇曲线**：编辑 `fanctl.sh` 中 `curve()` 的分段点，然后：

```bash
sudo systemctl restart omen-fan-curve
journalctl -u omen-fan-curve -f
```

**模块参数**：`/etc/modprobe.d/omen_wmi_boost.conf`

```ini
options omen_wmi_boost force_unsupported=1 persist=1 auto_boost=0 boot_mode=enable
```

- `boot_mode=enable` 只写 WMI `0x22`，不修改热档位（推荐）。
- `boot_mode=performance` 会额外写 `0x1a` 设置热档位，适合 `enable` 无效的机型。
- `force_unsupported=1` 用于非 `8D87` 验证板型。

---

## 排错

| 现象 | 排查 |
|---|---|
| GPU 仍停在 80 W | `gpu-test status` 看 `ctgp/dtgp`；确认 `nvidia-powerd` 为 `active`；检查 `journalctl -u nvidia-powerd` |
| powerd 报 `not allowed to own the service "nvidia.powerd.server"` | D-Bus 策略缺失或权限不是 644：`ls -l /usr/share/dbus-1/system.d/nvidia-powerd.conf` |
| powerd 报 `disable Dynamic Boost` | 解锁标志未生效，先 `sudo gpu-test enable`（或 `perf`）再重启 powerd |
| 模块拒绝加载 | 板型不在允许列表，需 `force_unsupported=1`（风险自负） |
| 写 `pwm1` 后转速不变 | 该机型 EC 不接受手动 PWM，改用 EC 自动曲线 |
| 内核升级后解锁失效 | 重新 `make -C external/.../omen_wmi_boost` 并 `sudo ./persist.sh install` |
| `nvidia-smi` 的 `power.limit` 查询返回 N/A | 驱动的查询 bug，用 `nvidia-smi -q -d POWER` 读取 |

---

## 安全提示

- **S5 供电风险**：解锁后若关机时仍有设备挂在常供电 USB 控制器上，独显供电可能不会完全切断。模块会在关机/重启时写回 `CTGP=0`，但请避免带设备合盖并拔掉电源。
- **散热**：解锁后 GPU 峰值功耗显著上升，请确认风扇曲线生效并监控温度（GPU 建议 < 85 °C）。
- **非验证板型**：`force_unsupported=1` 会跳过板型校验，WMI 命令在未验证硬件上的行为未知。
- **保修**：修改固件控制状态可能影响保修，请自行评估。

---

## 卸载

```bash
sudo systemctl disable --now omen-fan-curve
sudo ./persist.sh remove
sudo systemctl disable --now nvidia-powerd
sudo rm -f /usr/share/dbus-1/system.d/nvidia-powerd.conf
sudo ./install.sh --uninstall
```

---

## 致谢与许可

- 内核模块与解锁思路来自 [5080-Unlock_Linux](https://github.com/IzzieBoopers/5080-Unlock_Linux)（GPL-2.0），以 submodule 形式引入，独立分发。
- 本仓库的脚本、单元与文档采用 MIT 许可，见 [`LICENSE`](LICENSE)。
