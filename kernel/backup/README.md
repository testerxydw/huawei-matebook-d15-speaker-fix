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
  （I2C 失联、JD 电路断电），插拔检测冻结直至重启。
- **es8316 补丁版**：JD 电源域保持（`force_enable_pin` Bias/Analog power）+ 双边沿
  中断 + 软件 debounce + regmap 错误检查 + 锁外 I2C。
- **sof_es8336 原版**：耳机功放 GPIO 随扬声器播放状态禁用（插耳机路由切走后
  Speaker widget OFF → GPIO 高 → 耳机功放被禁 → 耳机无声）；`sof_es8336_remove()`
  泄漏 `gpio_headphone`（驱动重载报 -EBUSY）。
- **sof_es8336 补丁版**：耳机功放 GPIO 不再随扬声器播放状态驱动（保持 probe 时
  低电平 = 使能）；remove 补上泄漏的 `gpiod_put`。

## 部署 / 切换

**当前部署状态（2026-08-20）**：

| 模块 | 部署版本 | 说明 |
|------|---------|------|
| snd-soc-es8316 | **原版**（`41787385`） | 补丁版导致键盘失效，已回退 |
| snd-soc-sof_es8336 | **补丁版**（`664371F5`） | 耳机功放修复，无已知问题 |

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
