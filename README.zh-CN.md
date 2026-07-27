# 华为 MateBook D15 —— Linux 下扬声器/耳机自动切换修复

修复华为 MateBook D15（BOD-WXX9）在 Linux 下扬声器与耳机同时出声的问题。应用本修复后：插入耳机时扬声器自动静音，且**拔掉耳机时扬声器能正常恢复出声**——无需重启。

> 本仓库同时适用于 BoF-XX 机型：脚本会在运行时自动探测所有板型相关参数，无需手动修改。

## 适用硬件

| 项目 | 值 |
|------|-----|
| 笔记本 | 华为 MateBook D15 |
| 主板 | BOD-WXX9-PCB-B4（原始），**BoF-XX / BoF-XX-PCB**（本机） |
| 测试系统 | Ubuntu 24.04 LTS，内核 6.17.0-23-generic（BOD）；滚动内核 6.18（BoF-XX） |
| 音频编解码器 |  Everest Semi ES8336（ACPI：ESSX8336） |
| 扬声器功放 | 华为定制 HWSP0001（无 Linux 驱动） |

脚本**在运行时自动探测所有板型相关参数**——I2C 总线、Headphone-Jack 的 ALSA 控件、扬声器音量控件，甚至功放使能的 **GPIO 线号**（通过 `iasl` 从 DSDT 解析，见 [GPIO 线号](#gpio-线号)）。两种主板都无需手动编辑。

其他使用 HWSP0001 的 MateBook 机型也可能适用——见 [兼容性](#兼容性)。

## 问题描述

Linux 没有 `HWSP0001` 扬声器功放的驱动。BIOS 在开机时通过 SMM 初始化一次（在系统加载前），但 Linux 中没有机制去：

- 在插入耳机时把扬声器静音
- 在功放断电后重新初始化它

标准的 ALSA/DAPM 控件、`snd_soc_sof_es8336` 驱动的 WirePlumber 路由以及 GPIO 调整都无效，因为它们无法控制真正的功放芯片。

## 工作原理

通过 DSDT 分析与 I2C 寄存器 dump，我们确认：

- 扬声器功放（`HWSP0001`）位于 I2C 总线上，地址为 **0x58**（左）和 **0x5B**（右），速率 400kHz。具体总线因机型而异：**BOD-WXX9 为 i2c-2**，**BoF-XX 为 i2c-4**。脚本会从 `/sys/bus/i2c/devices/i2c-HWSP0001:00` 自动探测。
- **功放使能 GPIO 线号**因机型而异（例如 **BOD-WXX9 为 267**，**BoF-XX 为 145**），但会从 DSDT **自动探测**——见 [GPIO 线号](#gpio-线号)。
- 经过一次 GPIO 电源循环（`0 → 1`）后，功放在 I2C 上恢复工作，但处于默认（静音）状态
- 通过 `i2cset` 写回 BIOS 初始化的 27 个寄存器值即可完整恢复功放

修复由一个 `systemd` 服务完成：

1. 通过 `alsactl monitor` 监视 ALSA 的 Headphone Jack 控件
2. 插入耳机时把功放使能 GPIO 拉**低**（功放关闭）
3. 拔出耳机时把 GPIO 拉**高**（功放开启），随后回放 I2C 寄存器初始化
4. 在“真正拔掉耳机”的事件中，通过 PipeWire（`wpctl`）**先把扬声器音量设为 0（静音）**，再重新上电功放（避免炸音）；开机 / 插入耳机时音量保持不变

```
检测到插孔事件
        │
   jack=on  ──→ gpio=0  （功放关闭，耳机工作）
   jack=off ──→ gpio=1  （功放开启）
                    │
                    ▼
             i2cset 回放
         27 个寄存器 → 0x58 与 0x5B
                    │
                    ▼
           扬声器恢复出声 ✓
```

## 拔掉耳机时的安全静音（音量自动归 0）

在本机上，单一的 PipeWire sink 同时驱动耳机和扬声器，并且 **PipeWire 拥有音量控制权**——仅写 ALSA 混音器会被 PipeWire 立即覆盖。因此当你**拔掉耳机**时，脚本会以你的桌面用户身份驱动 `wpctl`，在功放重新上电**之前**把扬声器音量**强制设为 0（静音）**，这样它绝不会以之前耳机的音量突然炸响；之后你可以用音量键 / 混音器手动调大。

开机和插入耳机时音量**保持不变**（你的耳机音量不会被改动）。音量仅在真正发生插孔跳变时被修改一次，之后用户手动调整不会被脚本反复压制。

## 依赖要求

```bash
sudo apt install i2c-tools gpiod alsa-utils
```

## 安装

```bash
git clone https://github.com/YOUR_USERNAME/huawei-matabook-d15-speaker-fix
cd huawei-matabook-d15-speaker-fix
sudo bash install.sh
```

就这么简单。服务会立即启动并在开机时启用。

## 手动安装

```bash
sudo cp huawei-speaker-mute.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/huawei-speaker-mute.sh
sudo cp huawei-speaker-mute.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now huawei-speaker-mute.service
```

## 验证是否生效

```bash
sudo systemctl status huawei-speaker-mute.service
```

插入耳机 → 扬声器应静音。  
拔掉耳机 → 扬声器应在约 0.5 秒内恢复出声。

## 兼容性

本修复在 **BOD-WXX9-PCB-B4** 上开发并测试。其他使用相同 `HWSP0001` 功放的 MateBook 机型可能也适用。

检查你的主板是否有 `HWSP0001`：

```bash
ls /sys/bus/acpi/devices/ | grep -i hw
# 应显示：HWSP0001:00
```

检查功放所在的 I2C 总线（不同主板总线不同——BOD-WXX9 为 i2c-2，BoF-XX 为 i2c-4）：

```bash
readlink -f /sys/bus/i2c/devices/i2c-HWSP0001:00
# BOD-WXX9 -> .../i2c_designware.2/i2c-2/...
# BoF-XX   -> .../i2c_designware.3/i2c-4/...
```

脚本会自动探测，因此通常无需手动设置 `I2C_BUS`。

### GPIO 线号

功放使能 GPIO 线号**因机型而异**，但脚本现在会在启动时**自动探测**：它用 `iasl` 反汇编 DSDT，并解析 HWSP 设备 `_INI` 方法中的 `GNUM(...)` 参数（`line = GPCL[group][6] + (arg & 0xFFFF)`）。已验证的值：

**BOD-WXX9 为 267**，**BoF-XX 为 145**。若缺少 `iasl` 或解析失败，则回退到 `GPIO_LINE=145`。

在自己的主板上验证：

```bash
sudo apt install acpica-tools
sudo iasl -d /sys/firmware/acpi/tables/DSDT
grep -n -A6 'Device (HWSP)' dsdt.dsl
# 寻找：  PIN1 = GNUM (0x090B00XX)   （BOD）   或   GNUM (0x090800XX) （BoF）
# GPIO 线号 = GPCL[group][6] + 0xXX
#   BOD: 0x090B000B -> GPCL[0x0B][6]=256 + 0x0B = 267
#   BoF: 0x09080001 -> GPCL[0x08][6]=144 + 0x01 = 145
```

所有参数仍可通过环境变量覆盖（极少需要）：

```bash
GPIOCHIP=gpiochip0
GPIO_LINE=         # 留空 -> 从 DSDT 自动探测（回退 145）
JACK_NUMID=        # 留空 -> 从 “Headphone Jack” 自动探测
I2C_BUS=           # 留空 -> 从 i2c-HWSP0001:00 自动探测
SPK_VOL_NUMID=     # 留空 -> 自动探测（DAC/Speaker/Master Playback Volume）
SPK_VOL_DEFAULT=70 # 仅在说明文档中使用；音量不会被强制设置（仅在拔耳机时归 0）
```

**关于寄存器值：** `reinit_amp()` 中的值是 HWSP0001 的**使能**值（BOD-WXX9 / BoF-XX 相同芯片）。对 BoF-XX 尤为重要：i2c-4 上刚开机的 `i2cdump` 显示的是功放**默认的静音状态**，这与 BOD-WXX9 文档记载的静音默认值一致——这意味着 BoF-XX 的 BIOS **不会**在开机时初始化功放。因此**切勿**把刚开机的 dump 拷进脚本；脚本中现有的使能值才是真正能发声的值。仅当你有来自不同板型修订、确认“可正常发声”的 dump 时，才需要重新审视这些值。

如果想查看当前状态，在正确的总线上 dump：

```bash
# BOD-WXX9：
sudo i2cdump -y -f 2 0x58
sudo i2cdump -y -f 2 0x5B
# BoF-XX（功放在 i2c-4 上！——预期看到的是静音默认 dump）：
sudo i2cdump -y -f 4 0x58
sudo i2cdump -y -f 4 0x5B
```

## 技术细节

### DSDT 分析

ACPI 中的 HWSP0001 设备：

- **BOD-WXX9**：`\_SB_.PC00.I2C3.HWSP` —— I2C3 上两个 I2C 资源 0x58/0x5B，400kHz；GPIO 使能引脚通过 `GNUM(0x090B000B)` → gpio-267
- **BoF-XX**：`\_SB_.PC00.I2C5.HWSP` —— 同样的 0x58/0x5B，400kHz，但在 I2C5（i2c-4）上；GPIO 社区同为 Intel PCH，请用 [GPIO 线号](#gpio-线号) 中的方法确认确切线号

`_INI` 只在资源模板中设置 GPIO 引脚号——它**不会**通过 I2C 初始化功放。

真正的 I2C 初始化发生在 Linux 启动前的 BIOS 固件（SMM）中。没有任何 ACPI 方法会触发它。

### 为什么 acpi_call 没有帮助

安装 `acpi-call-dkms` 并检查 DSDT 后，HWSP0001 的 `_INI` 方法是：

```c
Method (_INI, 0, NotSerialized) {
    PIN1 = GNUM(0x090B000B)  // 只是把 gpio 号写入资源模板
}
```

没有任何 I2C 写操作。真正的初始化在 BIOS 的 SMM 代码中。

### 寄存器差异（BIOS 初始化值 vs 默认值）

| 寄存器 | BIOS 值 | 默认（电源循环后） |
|--------|---------|-------------------|
| 0x01 | 0x69 | 0x38 |
| 0x03 | 0x16 | 0x0c |
| 0x04 | 0x80 | 0x00 |
| 0x05 | 0x0c | 0x08 |
| 0x06 | 0x11 | 0x10 |
| 0x07 | 0x93 | 0x43 |
| 0x09 | 0x0b | 0x03 |
| 0x0b | 0x4b | 0x4a |
| 0x0c | 0x00 | 0x03 |
| 0x0d | 0x77 | 0xdd |
| 0x0f | 0x51 | 0x23 |
| 0x10 | 0x58 | 0x08 |
| 0x58 | 0x00 | 0x80 |
| 0x59 | 0x80 | 0x00 |
| 0x61–0x69 | 见脚本 | 不同 |
| 0x71–0x74 | 见脚本 | 不同 |

## 已知限制

- HWSP0001 背后的具体芯片型号未知（可能是 TI TAS25xx 或类似）。没有数据手册，我们无法得知每个寄存器的含义。
- 寄存器值取自某一块特定主板。如果你的主板生产批次或校准不同，值可能会有差异。
- 本仓库中部分版本包含的、针对 BOD-WXX9 的 `snd_soc_sof_es8336` DMI quirk 补丁会激活 DAPM 扬声器切换，但对实际声音输出没有影响——真正的功放是 HWSP0001，不受编解码器驱动控制。

## 贡献

如果你有使用 HWSP0001 的其他 MateBook 机型，请提交 issue 并附上：

- 主板型号（`cat /sys/class/dmi/id/board_name`）
- `readlink -f /sys/bus/i2c/devices/i2c-HWSP0001:00` 的输出
- 你的功放寄存器 dump（刚开机、任何插孔事件之前）
- GPIO 号（来自 `cat /sys/bus/acpi/devices/HWSP0001:00/path` + DSDT 分析）

## 许可证

MIT
