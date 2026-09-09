# kernel/ — 音频驱动模块版本存档

本项目内同时保存两个音频内核模块的**原版**与**补丁版**，共四个模块文件：

```
kernel/backup/   原版（发行版自带，未改动）——回退用
kernel/patched/  补丁版（本项目编译）——部署用
```

部署映射（ostree 不可变系统，fstab bind mount，见 `/etc/fstab`）：

```
/persistent/snd-soc-es8316.ko.zst      → /usr/lib/modules/<kver>/kernel/sound/soc/codecs/snd-soc-es8316.ko.zst
/persistent/snd-soc-sof_es8336.ko.zst  → /usr/lib/modules/<kver>/kernel/sound/soc/intel/boards/snd-soc-sof_es8336.ko.zst
```

## 版本说明

| 目录 | 文件 | srcversion | md5 |
|------|------|-----------|-----|
| `backup/`（原版） | `snd-soc-es8316.ko.zst` | `417873854FBE7975CD19D15` | `acdf59b337ea55202d8088482945b497` |
| `backup/`（原版） | `snd-soc-sof_es8336.ko.zst` | `C02936E8387E8C4E962EA24` | `d008caff2b1429b5488bf2b5e220ffa9` |
| `patched/`（补丁版） | `snd-soc-es8316.ko.zst` | `892945FF6EA5C30AD111508` | `aeb50ab9f79ab75e1028050acbed2877` |
| `patched/`（补丁版） | `snd-soc-sof_es8336.ko.zst` | `664371F5AFB39254F7DF5D5` | `7f4c1fae7ee1e97bbb66043888a0beae` |

> ⚠️ **es8316 补丁版已知缺陷：会导致键盘不可用（用户多次实测稳定复现，8/19）。**
> 键盘为 i8042 PS/2（IRQ 1），根因未定位（怀疑与双边沿 IRQ / force_enable_pin
> 保持电源域 / GPIO 域 ACPI 事件交互有关）。**当前不部署 es8316 补丁版，
> 部署位保持原版**；补丁版仅存档，待根因排查后再考虑启用。

### 原版 vs 补丁版差异

- **es8316 原版**：无 JD 电源域保持修复，拔出耳机后 codec 掉电进 deep shutdown
  （I2C 失联、JD 电路断电），插拔检测冻结直至重启；JD 中断仅 `IRQF_TRIGGER_HIGH`
  （+ONESHOT+NO_AUTOEN，0x82004），**只能检测插入、拔出不产生事件**（2026-08-20
  实测 IRQ 计数恒 0）。
- **es8316 补丁版**：JD 电源域保持（`force_enable_pin` Bias/Analog power）+ 双边沿
  中断 + 软件 debounce + regmap 错误检查 + 锁外 I2C。
- **sof_es8336 原版**：`headphone = !speaker_en`（插耳机 GPIO 低=使能，**无耳机无声
  缺陷**）；`sof_es8336_remove()` 泄漏 `gpio_headphone`（驱动重载报 -EBUSY，真实缺陷）。
- **sof_es8336 补丁版**：删除 headphone GPIO 随播放状态驱动（多余改动，基于错误
  源码判断）；remove 补上泄漏的 `gpiod_put`（有效修复）。

### 原版源码（对比分析基准，2026-08-20 下载）

| 文件 | 来源 | 行数 |
|------|------|------|
| `snd-soc-es8316.c` | deepin-community/kernel 仓库 `linux-6.18.y` 分支 | 933 |
| `snd-soc-sof_es8336.c` | 同上 | 865 |

**已用 .ko 反汇编验证一致**：es8316 IRQ flags=`IRQF_TRIGGER_HIGH|ONESHOT|NO_AUTOEN`
（=0x82004）、电源保持用 `force_enable_pin_unlocked`（非 `force_enable_pin`）；
sof 123 行 `gpiod_set_value(gpio_headphone, !speaker_en)` 取反（对应 .ko 的 xor）、
remove 仅 `gpiod_put(gpio_speakers)`（headphone 泄漏，对应 .ko）。

⚠️ **勿与以下文件混淆**：`kernel/es8316.c`（用户修改版）与
`kernel/sof_es8336-patch/snd-soc-sof_es8336.c`（来源不明的旧版，123 行无取反）
**都不是原版**，仅作参考，禁止当作原版对比。

## 部署 / 切换

**当前部署状态（2026-08-20 晚）**：

| 模块 | 部署版本 | 说明 |
|------|---------|------|
| snd-soc-es8316 | **原版**（`41787385`） | 补丁版导致键盘失效，已回退 |
| snd-soc-sof_es8336 | **原版**（`C02936E8`） | ⚠️ 2026-08-20 晚回退：反汇编验证发行版原版 `headphone=!speaker_en`（插耳机 GPIO 低=使能，**无缺陷**），8/19 实证原版+原版组合插耳机有声；此前补丁基于与发行版不一致的工作区源码，且部署补丁版当日（8/20）出现开机 12~17 分钟 codec 掉电失声（唯一新变量），故回退原版。补丁版仅存档 |

**注意（历史教训）**：工作区 `kernel/sof_es8336-patch/snd-soc-sof_es8336.c` 与发行版编译源码**不一致**（工作区 123 行 `gpiod_set_value(gpio_headphone, speaker_en)` 无取反，发行版 .ko 反汇编为 `!speaker_en`，已证实 deepin 官方源码为取反版）。对驱动打补丁前必须用 `objdump -d` 反汇编验证真实行为，不能盲信源码；对比分析请使用本目录的**原版源码**。

切换版本的完整流程：

1. 拷贝对应文件到部署位：
   - 部署补丁版：`sudo cp kernel/patched/snd-soc-es8316.ko.zst /persistent/`
   - 回退原版：`sudo cp kernel/backup/snd-soc-es8316.ko.zst /persistent/`
   - sof_es8336 同理
2. **必须重新 bind**（zstd/cp 原子写换 inode，旧 bind 仍指向旧内容）：
   ```bash
   sudo umount /usr/lib/modules/$(uname -r)/kernel/sound/soc/codecs/snd-soc-es8316.ko.zst
   sudo mount --bind /persistent/snd-soc-es8316.ko.zst /usr/lib/modules/$(uname -r)/kernel/sound/soc/codecs/snd-soc-es8316.ko.zst
   # sof_es8336 同理，路径换成 .../intel/boards/snd-soc-sof_es8336.ko.zst
   ```
3. 重启生效。

> ⚠️ 2026-08-19 曾发生：`/persistent/snd-soc-es8316.ko.zst` 被原版覆盖导致重启后
> JD 补丁失效（"拔插不切换"）。每次改动后务必校验：
> `modinfo -F srcversion /usr/lib/modules/$(uname -r)/kernel/sound/soc/codecs/snd-soc-es8316.ko.zst`
> 应为 `892945FF...`。

## 源码

- es8316 补丁源码：`../es8316.c`（用户版基底 + 3 处 FIX 已合入；原编译目录
  `es8316-patch/` 已删除，可参考 `sof_es8336-patch/` 结构重建）。
- sof_es8336 补丁源码：`../sof_es8336-patch/`（含本地 `hda_dsp_common.h` stub，
  仅声明 `hda_dsp_hdmi_build_controls()`，符号由系统模块
  `snd_soc_intel_hda_dsp_common` 提供）。
- sof_es8336 原版源码：`../sof_es8336.c`。
