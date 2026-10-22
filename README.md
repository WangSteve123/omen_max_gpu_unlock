# OMEN MAX 16（主板 8D41）Linux 调校工具

> 适用：HP OMEN MAX Gaming Laptop 16-ah0xxx（主板 8D41，BIOS F.23），Ubuntu 24.04 / 内核 7.0.0-38-generic。
> 本仓库是**用户态工具集**：风扇温度曲线、CPU RAPL 功耗墙调节、GPU TGP 解锁验证与最小化持久化。真正执行 175 W 解锁的内核模块来自第三方 GPL 项目 [5080-Unlock_Linux](https://github.com/IzzieBoopers/5080-Unlock_Linux)，**不包含**在本仓库中。
>
> **English**: userspace toolkit for HP OMEN MAX 16-ah0xxx (board 8D41) on Linux — fan curve via hp-wmi PWM, CPU RAPL limits, NVIDIA TGP unlock verification, and minimal boot persistence for the third-party `omen_wmi_boost` kernel module.

## 快速开始

```bash
git clone https://github.com/WangSteve123/omen_max_gpu_unlock.git ~/omen_max_gpu_unlock
cd ~/omen_max_gpu_unlock
sudo ./install.sh --with-fan     # 装到 /usr/local/sbin，并启用风扇曲线
status                            # 一键巡检
```

安装后可直接使用的命令：`status`、`fanctl`、`pl`、`persist`、`gpu-test`、`omen-fan-curve`。
（下文示例仍用仓库内路径 `~/omen-power/xxx.sh`；已执行 `install.sh` 时去掉路径即可。）

| 脚本 | 用途 |
|---|---|
| `status.sh` | 只读巡检：档位、RAPL、pstate、风扇、温度、GPU 限值、模块状态 |
| `fanctl.sh` | 风扇：`status` / `auto` / `manual <0-255>` / `curve --dry-run` / `daemon` |
| `pl.sh` | CPU 功耗墙：`status` / `<PL1> [PL2]` / `reset`，写入后自动回读校验 |
| `gpu-test.sh` | 分阶段验证 TGP 解锁：`probe`（只读）/ `enable` / `perf` / `off` |
| `persist.sh` | 把 `.ko` 装进 `extra/` 并配置开机加载（不含第三方服务） |
| `install.sh` | 安装/卸载上述脚本与 systemd 单元 |

> 初始快照（2026-10-22）：GPU 锁 80 W（硬件上限 175 W）；CPU PL1=PL2=170 W（三个档位实测都不变）；`nvidia-powerd` 未启用；`omen_wmi_boost` 未安装。

---

## ✅ 最终落地结果（2026-10-22 实测，已重启验证）

| 子系统 | 结果 | 生效方式 |
|---|---|---|
| GPU 功耗墙 | **80 W → 150 W 基础 / 175 W 峰值** | `omen_wmi_boost`（`boot_mode=enable`）+ `nvidia-powerd` |
| GPU 负载实测 | 轻载 60–77 W，墙随负载 166→170 W；重载可达 175 W | Dynamic Boost 动态协商 |
| CPU 功耗墙 | **170 W / 170 W（未改动）** | EC 固定，三档位均不变 |
| 风扇 | 温度曲线 0–255（当前 127 / 50%，3000–3200 RPM） | `omen-fan-curve.service`（hp-wmi PWM） |
| 重启持久化 | 全部自动恢复 | `modules-load.d` + `modprobe.d` + systemd |

### 与网上文章/仓库默认不一致的四个坑（本机实测）

1. **8D41 的 CTGP/DTGP 本来就是 1**，不需要模块去"打开"。真正卡住 80 W 的是 `nvidia-powerd` 没运行。
2. **`nvidia-powerd` 的 D-Bus 策略文件缺失**，且 `cp` 后权限是 `600`，`dbus-daemon`（`messagebus` 用户）读不到 → 必须 `chmod 644`，否则 powerd 拿不到 `nvidia.powerd.server` 并退出。
3. **不要直接跑仓库的 `install.sh`**：它会装 Victus S 的 `omen-wmi-fan-control`（走 0x2e/0x2f，非本机路径）和 Fedora 专用 kernel-install hook。本机只取内核模块 + 最小配置。
4. **风扇用 hp-wmi 的 `pwm1`（0–255）**，不是模块里的 WMI 风扇表（`speed_min=19 speed_max=60` 是另一套原始档位）。

### 本机落地文件

| 文件 | 作用 |
|---|---|
| `/lib/modules/7.0.0-38-generic/extra/omen_wmi_boost.ko` | 解锁模块（2.0.2，`force_unsupported=1`） |
| `/etc/modules-load.d/omen_wmi_boost.conf` | 开机自动加载 |
| `/etc/modprobe.d/omen_wmi_boost.conf` | `force_unsupported=1 persist=1 auto_boost=0 boot_mode=enable`（只写 0x22，不碰热档位） |
| `/etc/systemd/system/nvidia-powerd.service` | 从 `/usr/share/doc/nvidia-kernel-common-595/` 复制 |
| `/usr/share/dbus-1/system.d/nvidia-powerd.conf` | 自建 D-Bus 策略，**必须 644** |
| `/etc/systemd/system/omen-fan-curve.service` | 风扇温度曲线 |

> ⚠️ 内核升级后 `extra/` 里的模块不会自动重建：需要重新 `make -C ~/5080-Unlock_Linux/omen_wmi_boost` 再 `sudo ~/omen-power/persist.sh install`。

---

## 0. 先看结论

| 墙 | 当前 | 理论上限 | 能不能调 | 怎么调 |
|---|---|---|---|---|
| GPU TGP | **80 W** | 175 W | 能，需第三方内核模块 | cTGP/PPAB WMI 0x22 + `nvidia-powerd` |
| CPU PL1/PL2 | **170 W / 170 W** | 170 W | 档位改不了它；只能试 RAPL 直写或降频 | 见第 3 节 |
| 风扇 | EC 自动，1900/2100 RPM | — | 能 | `pwm1_enable=1` + `pwm1` |

**一句话**：GPU 的 80 W 是 HP 固件没收到 cTGP/PPAB 解锁命令造成的，属于内核驱动缺省行为；CPU 的 170 W 是固定值，切 performance/balanced/low-power 都不会变，OS 侧没有更高的合法档位。

> 实测记录（2026-10-22，本机）：三档切换均成功，`platform_profile` 依次变为 performance / balanced / low-power，EPP 依次为 `performance` / `balance_performance` / `power`；但 `constraint_0/1_power_limit_uw` 三档下**恒为 170000000**，风扇 1900/2100 RPM 也不变。说明 `hp-wmi` 的 PL1/PL2 "actualization" 对这块 8D41 没有实际下发（与 `Unknown EC layout` 告警一致）。

---

## 1. 为什么 GPU 只有 80 W

1. HP 在 Windows 下由 OMEN Gaming Hub 发两条 WMI：先设热档位，再发 `HPWMI_SET_GPU_THERMAL_MODES_QUERY`（命令 0x22，`ctgp_enable=1, ppab_enable=1`）解锁 TGP。
2. 本机 `hp-wmi` 模块里**确实有**这条命令的实现（模块内可见 `ctgp_enable` / `ppab_enable` / `HPWMI_SET_GPU_THERMAL_MODES_QUERY` 字符串），但它只对 `hp_wmi_feature_boards[]` 里的机型调用。
3. 8D41 走的是 `omen_v1_no_ec_thermal_params` 分支，所以只设了热档位、没发 0x22 → BIOS 不抬 NvPCF 预算 → `nvidia-smi` 永远 80 W，`Max Power Limit` 却是 175 W。
4. 上游补丁（2026-09，`platform/x86: hp-wmi: add cTGP and PPAB support for Omen`）**v1 被否、v2 已移除 cTGP/PPAB**，所以短期内核不会修。
5. 另外本机 `nvidia-powerd` 服务单元没装（二进制在 `/usr/bin/nvidia-powerd`，unit 只在 `/usr/share/doc/...` 里），即使解锁也没有协商方。

---

## 2. GPU 解锁步骤（方案 A：第三方模块 `omen_wmi_boost`）

> ⚠️ 风险：该模块作者只在 8D87 验证过，8D41 属于未验证板型，需要 `--force-unsupported`。它直接写 EC/WMI，可能造成风扇/功耗行为异常、休眠问题，极端情况需清 CMOS。**先读 `install.sh`，再决定是否执行。**

### 2.1 装依赖

```bash
sudo apt update
sudo apt install -y git build-essential dkms "linux-headers-$(uname -r)"
```

### 2.2 获取并人工检查脚本

```bash
git clone https://github.com/IzzieBoopers/5080-Unlock_Linux.git ~/5080-Unlock_Linux
cd ~/5080-Unlock_Linux
less install.sh          # 至少确认没有奇怪的 curl | sh、没有删系统文件
```

### 2.3 安装（Ubuntu 是 GCC 内核，不要加 LLVM=1）

```bash
cd ~/5080-Unlock_Linux
sudo ./install.sh --force-unsupported
```

> CachyOS/Clang 内核才需要 `sudo env LLVM=1 CC=clang LD=ld.lld ./install.sh`。本机 Secure Boot 已关闭，未签名模块可以直接加载。

### 2.4 以 performance 模式加载

```bash
sudo modprobe -r omen_wmi_boost 2>/dev/null
sudo modprobe omen_wmi_boost boot_mode=performance auto_boost=1 persist=1
cat /sys/kernel/omen_wmi_boost/gpu_state     # 期望看到 ctgp=1 ppab=1
cat /sys/kernel/omen_wmi_boost/last_error    # 应为空
```

### 2.5 启用 nvidia-powerd（必需）

```bash
sudo cp /usr/share/doc/nvidia-kernel-common-595/nvidia-powerd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-powerd
systemctl status nvidia-powerd --no-pager
journalctl -u nvidia-powerd -b --no-pager | tail -20
```

- 如果日志里出现 `Client (presumably SBIOS) has requested to disable Dynamic Boost` → cTGP 解锁没生效，回 2.4 检查 `gpu_state`。
- 开机自动加载（若 `persist=1` 没有帮你持久化）：

```bash
echo omen_wmi_boost | sudo tee /etc/modules-load.d/omen_wmi_boost.conf
echo 'options omen_wmi_boost boot_mode=performance auto_boost=1 persist=1' | sudo tee /etc/modprobe.d/omen_wmi_boost.conf
```

### 2.6 验证（需要真正跑 GPU 负载）

```bash
# 另开一个终端压 GPU，例如
prime-run glxgears -info      # 或 nvtop / Unigine / CUDA 任务

watch -n1 'nvidia-smi --query-gpu=power.draw,power.limit,temperature.gpu,clocks.gr,pstate --format=csv'
```

期望：`power.limit` 从 80.00 W 上升到最高 175.00 W（随温度/负载协商），`power.draw` 能明显超过 80 W。

### 2.7 回滚

```bash
sudo modprobe -r omen_wmi_boost
cd ~/5080-Unlock_Linux && sudo ./uninstall.sh    # 若存在
sudo systemctl disable --now nvidia-powerd
sudo rm -f /etc/modules-load.d/omen_wmi_boost.conf /etc/modprobe.d/omen_wmi_boost.conf
reboot
```

### 2.8 方案 B（不推荐，了解即可）

自己改 `hp-wmi`：把 `8D41` 加进 `hp_wmi_feature_boards[]`（搭配 `omen_v1_legacy_board_params`），并在 `platform_profile_omen_set_ec()` 里调用 `victus_s_gpu_thermal_profile_set(true, true, 1)`，然后重编 `hp-wmi.ko`。可行但维护成本高，每次内核升级都要重来。等 8D41 进上游更省事。

---

## 3. CPU 功耗墙

### 3.1 现状解读

- `intel-rapl:0`：PL1 = PL2 = **170 W**（peak 295 W）。
- `constraint_0_max_power_uw = 55 W` 是 MSR 里上报的**基础 TDP 字段**（275HX 正是 55 W），不是可写上限，别被它误导。
- PL2 时间窗 2440 µs 明显是无效回读，说明这几个值由 EC 下发、RAPL 只是镜像。
- **实测：切档位不改变 PL**。performance / balanced / low-power 三档下 PL1/PL2 恒为 170 W，只有 EPP（`performance` → `balance_performance` → `power`）和风扇曲线策略变化。也就是说 `hp-wmi` 的 "Triggering CPU PL1/PL2 actualization" 对 8D41 没有真正生效。

### 3.2 档位切换（已验证可用）

```bash
powerprofilesctl set balanced        # 或 performance / power-saver
powerprofilesctl get
cat /sys/firmware/acpi/platform_profile
cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference
```

三档实测结果：

| 档位 | platform_profile | EPP | PL1/PL2 |
|---|---|---|---|
| performance | performance | performance | 170 W |
| balanced | balanced | balance_performance | 170 W |
| power-saver | low-power | power | 170 W |

> 若某次 `set` 后没生效，先看 `ActiveProfileHolds` / `PerformanceInhibited`，再重试；本机没有 hold，实测可正常切换。

### 3.3 直接写 RAPL（唯一可能真正改 CPU 墙的路）

因为档位不会写 PL，手写值有机会保留：

```bash
# 先往下降测试（50W，低于 TDP 字段）
sudo sh -c 'echo 50000000 > /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw'
grep . /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
```

判读：
- `Invalid argument` → powercap 层按 `max_power_uw` 拒绝了，此路不通。
- 写成功但读回仍是 170 W → MSR 被 BIOS/EC 锁定，此路不通。
- 读回变成 50 W → 成功。想要的值写成 `/etc/systemd/system/cpu-powercap.service` 开机重放，并在 AC 插拔后复查是否被 EC 改回。

### 3.4 不碰 PL 的等效手段（推荐，安全）

```bash
powerprofilesctl set power-saver      # EPP=power，最省电
powerprofilesctl set balanced         # EPP=balance_performance

# 关睿频（降温最明显，性能损失也最大）
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# 限制最大频率（示例 3.5 GHz；对所有 policy 生效）
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo 3500000 | sudo tee "$p/scaling_max_freq" >/dev/null
done
```

注意本机是 `intel_pstate` + HWP：`governor=powersave`、EPP 主导实际频率，改 governor 到 `performance` 意义不大，优先改 EPP。

### 3.5 想更高？

170 W 是这台机器当前能读到的固定值，OS 侧没有更高档位；再往上只能改 BIOS/EC，风险极高，不建议。

---

## 4. 风扇联动（解锁 GPU 后必做）

- 手动控制已验证可用：`pwm1_enable=1` + `pwm1=200`，恢复用 `pwm1_enable=2`。
- 双风扇由单路 PWM 联动（`fan1`/`fan2` 反馈，只有 `pwm1`）。
- 手动固定转速会被 `hp-wmi` 的 keep-alive 周期性刷新，属正常现象；长期固定高转速会加速积灰、噪音大。

### 4.1 先用本目录的 `fanctl.sh`（推荐）

```bash
~/omen-power/fanctl.sh status          # 看温度/转速/PWM/模式
~/omen-power/fanctl.sh curve --dry-run # 只算目标值

# 关键验证：手动模式到底能不能改变实际转速
sudo ~/omen-power/fanctl.sh manual 200
sleep 5; ~/omen-power/fanctl.sh status   # RPM 应从 ~1900/2100 明显上升
sudo ~/omen-power/fanctl.sh auto
```

若 `manual 200` 后 RPM 完全不动，说明这块 8D41 的 EC 不接受手动 PWM，曲线方案不可行，只能靠 4.2。

### 4.2 常驻温度曲线

曲线：45 °C→PWM 100，55 °C→130，65 °C→170，75 °C→210，85 °C→255；取 CPU 封装与 GPU 温度的较大值；93 °C 强制满转，97 °C 自动交回 EC。

```bash
sudo ./install.sh --with-fan     # 安装脚本到 /usr/local/sbin 并启用曲线服务
systemctl status omen-fan-curve --no-pager
journalctl -u omen-fan-curve -f          # 看调节日志
```

停止并恢复 EC 自动：

```bash
sudo systemctl disable --now omen-fan-curve
sudo fanctl auto                          # 或 ./fanctl.sh auto
```

### 4.3 如果用 `omen_wmi_boost` 自带风扇控制器

模块新版自带 GPU 温控风扇服务，配置文件 `/etc/omen-wmi-fan-control.conf`，服务名 `omen-wmi-fan-control.service`。两者**不要同时开**，二选一：

```bash
cat /sys/kernel/omen_wmi_boost/fan_state
systemctl status omen-wmi-fan-control --no-pager
sudo /usr/local/sbin/omen-wmi-fan-control --dry-run --once
```

---

## 5. 风险与注意事项

1. **第三方模块未在 8D41 验证**：先用 `--force-unsupported` 前，确认能接受“可能需要重置 BIOS/CMOS”的后果。
2. **功耗叠加**：GPU 175 W + CPU 170 W 同时满载会超过适配器与散热设计，建议二者取其一满血，或给 CPU 设 100–120 W 上限（若 RAPL 可写）。
3. **内核升级**：每次升级需重建模块；用 DKMS 可自动，但 7.0.x 这种非标准版本要留意编译兼容性。
4. **温度红线**：`TCPU` critical 110 °C，主动降频从 103 °C 开始；长时间 95 °C+ 会加速老化。
5. 修改后务必用 `nvidia-smi` + `sensors`/`status.sh` 复核，不要只看“命令没报错”。

---

## 6. 一键巡检

```bash
./status.sh        # 或安装后直接 status
```

只读脚本，输出机型、档位、RAPL、pstate、风扇、温度、GPU 限值、模块状态。

---

## 7. 许可

本仓库脚本与文档为 MIT（见 `LICENSE`）。第三方 `omen_wmi_boost` 内核模块为 GPL-2.0，单独分发。
