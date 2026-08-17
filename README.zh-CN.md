# 华为 MateBook D15（BoF-XX）扬声器 / 耳机自动切换修复

> 适用机型：华为 MateBook D15 `BoF-XX`（同架构还有 `BOD-WXX9` 等，均使用 ES8336 编解码器 + HWSP0001 扬声器功放）。
> 本方案**完全在用户空间完成，无需重新编译内核**。
> 本项目初始代码来自上游 [MaximushkaBed/huawei-matebook-d15-speaker-fix](https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix)。上游解决了 HWSP0001 功放在 Linux 下「扬声器一直无声」的问题；本仓库在此基础上增加了耳机插拔时扬声器自动静音/恢复的联动控制，并完善了参数自动探测、防爆音音量保护与内核无关性验证。

## 1. 原理与问题

- **扬声器**由 `HWSP0001` 功放驱动（I2C 总线运行时自动探测，本机为 `i2c-3`，地址 `0x58`/`0x5B`）；**耳机**走 `ES8336` 编解码器独立路径，二者互不依赖。
- `HWSP0001` 没有 Linux 驱动：功放开机处于静音默认态，需通过 I2C 回放一组“使能”寄存器（`reinit_amp`）才能出声。
- 功放提供**软静音寄存器 `0x01`**：
  - 写 `0x00` → **仅静音扬声器**，耳机照常响（已实测验证）；
  - 写 `0x69` → 恢复扬声器。
- 插拔事件通过三级通道监听（见第 2 节）：主通道为 `sof_es8336` 驱动创建的 input 事件设备（`/dev/input/eventN` 的 `SW_HEADPHONE_INSERT`），辅以周期轮询与 `alsactl monitor` 兜底。

**机型差异（关键）**：功放供电 GPIO 是否需要用户态操控，因机型而异，脚本通过 DMI 自动判断：
- **BoF-XX 等新机型**：BIOS 开机已完成功放 GPIO 供电，用户态若再用 `gpioset` 拉该线，反而破坏 BIOS 建立的引脚状态、导致功放 I2C 永久不可访问（必须重启）。脚本判定 `NEEDS_GPIO=0`，**完全不碰 GPIO**。
- **BOD-WXX9 / BOHB-WAX9 等老机型**：BIOS 不初始化功放 GPIO，必须由用户态 `gpioset` 持续拉高供电脚，功放 I2C 才可访问。脚本判定 `NEEDS_GPIO=1`。

**原缺陷**：早期脚本在“插入耳机”时去翻转功放供电 GPIO 以图静音，但该方式既不能真正静音扬声器（GPIO 与功放静音无关），在 BoF-XX 上还会破坏 BIOS 已建立的 GPIO 状态。

**修复思路**：把“静音扬声器”的动作改为写功放软静音寄存器 `0x01=0x00`（只影响扬声器、不影响耳机），由用户空间脚本在插拔时自动执行；GPIO 是否由用户态拉取则交给 DMI 自动判定。

## 2. 具体修复项

脚本 `huawei-speaker-mute.sh` 在运行期完成以下工作（均为用户空间逻辑）：

- **DMI 自动判定 GPIO 策略**（`detect_dmi_gpio_needed`）：按 `product_name` 判断 `NEEDS_GPIO`。`BoF*` → `0`（不碰 GPIO）；`BOD*`/`BOH*` → `1`（用户态拉 GPIO 供电）。可用环境变量 `NEEDS_GPIO` 覆盖。
- **插拔三级监听**（保证任何机型都不漏事件）：
  1. 主通道：Python 监视器监听 `sof_es8336` 创建的 input 事件设备（`SW_HEADPHONE_INSERT`）+ 每 `POLL_INTERVAL` 秒轮询 ALSA 控件；
  2. 次通道：`alsactl monitor hw:0`（部分机型可能无事件，作为兼容）；
  3. 兜底：每 2 秒纯轮询 ALSA 控件。
- **软静音寄存器切换**（`set_amp`）：
  - 插入耳机（`val=0`）→ 写 `0x01=0x00`，只静音扬声器、耳机不受影响；
  - 拔掉耳机（`val=1`）→ 拉起 GPIO 供电（仅 `NEEDS_GPIO=1`）+ `reinit_amp()` 回放使能寄存器（`0x01=0x69` 及初始化序列），并触发 `unplug_volume_guard` 先把音量清零防爆音。
- **`reinit_amp()` 带读回验证与重试**：写入后回读 `0x01` 寄存器确认生效，失败自动重试（最多 3 次；`NEEDS_GPIO=1` 时按需重启 GPIO 供电）。
- **健康检查后台循环**（`health_check`，每 `HEALTH_CHECK_INTERVAL` 秒，默认 60s）：检查 `gpioset` 是否存活、功放 `0x01` 寄存器是否处于合法值（插耳机时 `0x00`、否则 `0x69`），异常则自动恢复；并在 PipeWire 会话就绪后补全音量保护。

常用环境变量（覆盖自动探测）：`GPIOCHIP`、`GPIO_LINE`、`JACK_NUMID`、`I2C_BUS`、`SPK_VOL_NUMID`、`NEEDS_GPIO`、`POLL_INTERVAL`、`HEALTH_CHECK_INTERVAL`。

> 注：早期曾探索过内核态修复（给 `es8336` 编解码器驱动加 `JD_INVERTED` 反相补丁，目录 `es8336-jack-invert/`）。由于本机插拔事件已能被用户空间脚本稳定监听，且功放软静音可达成同等效果，**最终采用上述用户空间方案**，更简单、可即时回退、无需编译内核模块。

## 3. 修复步骤（部署）

1. 安装脚本与 systemd 服务（需要 root）：
   ```bash
   sudo ./install.sh
   ```
   该脚本会把 `huawei-speaker-mute.sh` 安装到 `/usr/local/bin/`（若不可写则回退到 `/opt/`），并启用 `huawei-speaker-mute.service`（开机自启、自动监听插拔）。本机当前安装路径为 `/opt/huawei-speaker-mute.sh`。
   安装程序会**先自动检测并安装运行依赖**：`i2c-tools`（`i2cset`/`i2cget`）、`alsa-utils`（`amixer`/`alsactl`）、`libgpiod`/`gpiod`（`gpioset`）、`python3`（**必需**，用于 DSDT 解析与 input event 监听）、`acpica-tools`（`iasl`）。`wpctl`/PipeWire 为可选项，缺失时仅跳过拔耳机音量保护，不影响核心静音功能。

   仓库另含 `tools/` 目录，存放排障用诊断脚本（`jack_watch.py`、`pure_poll.py`、`event_sync_test.py`、`reg_watch.py`），其运行产生的日志已被 `.gitignore` 忽略。
2. 立即生效（无需重启）：
   ```bash
   sudo systemctl restart huawei-speaker-mute.service
   ```
3. 确认服务运行：
   ```bash
   systemctl status huawei-speaker-mute.service
   ```

如需手动控制（不依赖自动监听），脚本也支持子命令：
```bash
huawei-speaker-mute.sh mute     # 软静音扬声器（等价插入耳机效果）
huawei-speaker-mute.sh unmute   # 恢复扬声器
huawei-speaker-mute.sh status   # 查看功放 0x01 寄存器状态
```

## 4. 验证标准（检验修复是否成功）

逐项确认，全部满足即为修复成功：

| 场景 | 期望结果 | 判定 |
|------|----------|------|
| **插入耳机** | 扬声器**应无声**；耳机**应有声** | PASS 当扬声器静音且耳机正常 |
| **拔掉耳机** | 扬声器**应恢复有声**（先静音、用户调大音量后出声） | PASS 当拔掉后扬声器能出声 |
| **开机时插着耳机** | 扬声器**应无声**（脚本启动即按“已插入”软静音） | PASS 当开机插耳机扬声器不响 |
| **开机时不插耳机** | 扬声器**应有声** | PASS 当开机扬声器正常出声 |
| **插拔过程中无爆音** | 拔掉瞬间扬声器先清零音量再恢复，不应突然炸响 | PASS 当无“啪”声 |

辅助核查命令：
```bash
# 查看插入/拔出时功放 0x01 寄存器是否随之变化（0x00=静音，0x69=恢复）
huawei-speaker-mute.sh status

# 手动验证软静音效果
./huawei-speaker-mute.sh status          # 直接打印 0x58/0x5B 的 0x01 寄存器（0x00=静音，0x69=恢复）
i2cget -y -f <I2C_BUS> 0x58 0x01         # <I2C_BUS> 由脚本自动探测（本机 i2c-3）；0x00=静音，0x69=恢复
```

若某项不满足，优先检查：① 服务是否运行；② `Headphone Jack` 控件在插拔时是否确实翻转（可用 `alsactl monitor hw:0` 观察）；③ `i2cset` 是否能访问 `0x58/0x5B`（需 root）。

## 5. 回退

- 停止自动切换：`sudo systemctl stop huawei-speaker-mute.service`。
- 完全卸载：`sudo ./install.sh` 的反向操作（删除 `/usr/local/bin/huawei-speaker-mute.sh` 与禁用服务），或直接重装发行版原包。
- 本方案不修改内核，回退即恢复原始行为，无残留风险。

## 6. 内核无关性验证（确认不依赖内核改动）

本修复**没有修改任何内核文件、内核配置或内核模块**。证据如下：

1. **未编译/安装自定义内核模块**：内核自带的 `snd-soc-es8336.ko.zst` 仍位于 `/lib/modules/$(uname -r)/kernel/sound/soc/codecs/`；`/lib/modules/$(uname -r)/updates` 与 `/extra` 下无任何 `es83xx` 自定义模块；`dkms status` 仅显示与本修复无关的 `deepin-anything`。
2. **内核配置未被改动**：将运行中的 `/proc/config.gz` 与发行版原始 `/boot/config-$(uname -r)` 做 `diff`，结果为 **完全一致（KERNEL_CONFIG_IDENTICAL）**。关键项如 `CONFIG_MODULE_FORCE_UNLOAD`（未置位，与早前 `rmmod -f` 失败现象一致）、`CONFIG_SND_SOC_ES8336=m` 均为发行版默认。
3. **项目源码改动范围**：`git diff` 显示仅改动用户空间脚本 `huawei-speaker-mute.sh` 与两份 README；早期探索内核补丁用的 `es8336-jack-invert/` 目录已删除，无任何残留。
4. **实现方式**：整个修复仅通过用户空间的 I2C 寄存器写（`i2cset`）＋ ALSA 控件监听（`alsactl monitor`）完成，不需要任何内核模块支持。

**结论：本修复完全独立于内核层，任何未修改内核的同类系统均可直接套用，且可随时回退、零残留。**

## 7. 通用性与可移植性评估

**核心思路可复用，但脚本本身面向 HWSP0001，不能直接套到其他设备。** 分两层看：

### 可复用的框架（与具体硬件无关）
- 用 `alsactl monitor` + input 事件设备（`SW_HEADPHONE_INSERT`）+ 周期轮询的**三级监听**感知插拔，兜底不漏事件；
- 插拔跳变时通过 PipeWire（`wpctl`，以桌面用户身份）清零/恢复扬声器音量，避免爆音；
- 通过 DMI 判定「BIOS 是否已接管功放 GPIO」（`NEEDS_GPIO`），区分需要/不需要用户态拉 GPIO 的机型；
- 用 systemd 服务常驻、开机自启，并辅以**健康检查后台循环**自动恢复异常。

这套"用户空间监听插拔 → 控制功放/音量"的范式，适用于所有"耳机与扬声器切换异常、且希望用软方式控制扬声器"的 Linux 设备。

### 设备相关的部分（需按硬件调整）
- `detect_i2c()` 依赖 `i2c-HWSP0001:00` 这个 ACPI 设备名——其他功放不会有此节点，探测失败并退出；
- `set_amp()` 里的软静音寄存器（`0x01=0x00`）、使能寄存器序列（`reinit_amp`）和 I2C 地址（`0x58/0x5B`）都是 HWSP0001 专属；
- `detect_gpio()` 解析 DSDT 中 HWSP 设备的 `GNUM()` 参数得到功放供电 GPIO 线号，同样是机型专属。

### 移植到其他设备的条件
要把本方案用到另一台机器，需要满足：
1. 扬声器功放可通过 I2C（或类似可写接口）访问，且有"软静音"寄存器；
2. 耳机走独立于扬声器功放的路径（软静音扬声器不会同时静音耳机）——本机 ES8336 独立路径满足；
3. 系统中能找到可监听的插拔事件源（ALSA `Headphone Jack` 或某个 GPIO/输入事件）。

满足上述条件时，只需替换 `set_amp()` 中的 I2C 总线/地址/寄存器值、`reinit_amp()` 的初始化序列，以及（若仍依赖供电 GPIO）`detect_gpio()` 的解析逻辑，即可复用本脚本框架。

**结论**：`huawei-speaker-mute.sh` 是 HWSP0001 机型的成品修复；它不是一个"开箱即用"的通用工具，但其"监听插拔 ＋ 软静音功放 ＋ 音量保护"的架构可直接作为其他同类设备的模板。
