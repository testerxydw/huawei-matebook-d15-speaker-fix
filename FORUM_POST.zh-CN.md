# 华为 MateBook 扬声器/耳机切换修复脚本（纯用户空间，无需编译内核）

> 适用：搭载 **HWSP0001 扬声器功放**的华为 MateBook（已验证 **BoF-XX / D15**、**BOD-WXX9** 等）。
> 本仓库：https://gitee.com/xiyidaiwa/huawei-matebook-d15-speaker-fix
> 原始项目：基于 [MaximushkaBed/huawei-matebook-d15-speaker-fix](https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix) 适配与优化而来（在其基础上针对本机做了用户空间脚本层面的适配，未改动内核）。

---

## 一句话结论

如果你的华为 MateBook 用的是 HWSP0001 功放，在 Linux 下遇到「扬声器根本不出声」或「插拔耳机时扬声器/耳机切换异常（插耳机扬声器还在响、拔耳机没声等）」，**本脚本可以一键修复，且完全不碰内核、可随时回退**。

---

## 先确认你的机器是否适用（10 秒）

```bash
ls /sys/bus/i2c/devices/ | grep -i HWSP
```

- 有输出（如 `i2c-HWSP0001:00`）→ 基本适用，直接往下看；
- 无输出 → 你的功放不是 HWSP0001，本脚本不能直接用（见文末「通用性说明」）。

---

## 问题现象

HWSP0001 功放在 Linux 下没有驱动，存在两个层面的问题：

- **最基础的问题（上游项目已解决）**：功放开机处于静音默认态，没有任何驱动去初始化它 → **扬声器一直无声**。上游项目通过功放供电 GPIO 上电 + I2C 回放一组「使能」寄存器（`reinit_amp`）让扬声器出声。
- **插拔切换问题（本仓库新增解决）**：即便扬声器能出声，仍存在切换异常——插入耳机时系统不会把扬声器静音 → 扬声器、耳机同时出声；开机插着耳机扬声器可能一直响；部分机型拔掉耳机后扬声器反而没声。

根因：该功放没有可用的内核驱动。让扬声器出声需上电 GPIO + 回放使能寄存器；而「插拔时静音扬声器」必须写功放自己的软静音寄存器 `0x01=0x00`，而非翻转某个 GPIO。

---

## 解决方案亮点

- ✅ **纯用户空间**：只靠 `i2cset` 写功放寄存器 + `alsactl monitor` 监听插拔，**不编译、不替换任何内核模块**。
- ✅ **参数自动探测**：I2C 总线、`Headphone Jack` 控件、功放供电 GPIO 线号均在运行时自动探测（HWSP0001 机型开箱即用）。
- ✅ **只静音扬声器、不影响耳机**：写功放软静音寄存器 `0x01=0x00`，耳机走 ES8336 独立路径照常响（已实测）。
- ✅ **防爆音**：拔掉耳机瞬间先把扬声器音量清零，再恢复功放，不会「啪」地炸响。
- ✅ **开机自启 + systemd 常驻**，插拔实时联动。
- ✅ **可即时回退**：停止服务即恢复原始行为，零残留。

---

## 使用方法

```bash
git clone https://gitee.com/xiyidaiwa/huawei-matebook-d15-speaker-fix
cd huawei-matebook-d15-speaker-fix
sudo ./install.sh
sudo systemctl restart huawei-speaker-mute.service
```

验证（全部满足即修复成功）：

| 场景 | 期望 |
|------|------|
| 插入耳机 | 扬声器无声，耳机有声 |
| 拔掉耳机 | 扬声器恢复（调大音量后出声） |
| 开机插着耳机 | 扬声器无声 |
| 开机不插耳机 | 扬声器有声 |
| 插拔过程 | 无爆音 |

排障命令：

```bash
./huawei-speaker-mute.sh status   # 查看功放 0x01 寄存器（0x00=静音，0x69=恢复）
systemctl status huawei-speaker-mute.service
alsactl monitor hw:0              # 观察 Headphone Jack 是否随插拔翻转
```

---

## 关于「是否通用」的诚实说明

本脚本**不是对所有笔记本通用的万能工具**，它的自动探测锚定的是 HWSP0001 的 ACPI 标识，因此：

1. **HWSP0001 同族机型**（BoF-XX、BOD-WXX9 等）：开箱即用，自动找控制点，直接 `install.sh`。
2. **其他功放芯片的机型**：不能自动修复。需要用 `i2cdetect`/`i2cdump` 找到你功放的 I2C 地址与软静音寄存器，再替换脚本里 `set_amp()` 的地址/寄存器值和 `reinit_amp()` 的初始化序列即可复用整套框架。脚本里这些设备相关常量都集中、注释清晰，改起来不复杂。

移植的前提条件（满足即可套用框架）：
- 扬声器功放可以通过 I2C（或类似接口）访问，且有「软静音」寄存器；
- 耳机走独立于扬声器功放的路径（软静音扬声器不会误伤耳机）；
- 系统里有可监听的插拔事件源（ALSA `Headphone Jack` 或某个 GPIO/输入事件）。

---

## 内核无关性

已验证：运行内核配置 `/proc/config.gz` 与发行版原始 `/boot/config-$(uname -r)` 完全一致，未装入任何自定义内核模块。修复 100% 在用户空间完成，任何未改内核的同类系统都能直接用。

---

## 项目来源与致谢

- **原始项目**：[MaximushkaBed/huawei-matebook-d15-speaker-fix](https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix) —— 本仓库的初始代码与整体思路来自该上游项目。它解决了最基础的问题：**HWSP0001 功放在 Linux 下扬声器一直无声**（通过功放供电 GPIO 上电 + I2C 回放使能寄存器让扬声器出声），感谢原作者。
- **本仓库的改动**：在其基础上针对本机（BoF-XX）适配与优化，主要**增加了耳机插拔时扬声器自动静音/恢复的联动控制**（改用功放软静音寄存器 `0x01=0x00`：插入耳机静音扬声器、拔出恢复），并补充了参数自动探测、防爆音音量保护、内核无关性验证与可移植性文档。

欢迎同机型或同类问题的朋友试用并反馈。如果你的机器是 HWSP0001 但行为异常，请在 issue 里贴出 `huawei-speaker-mute.sh status` 与 `alsactl monitor hw:0` 的输出，方便一起完善。
