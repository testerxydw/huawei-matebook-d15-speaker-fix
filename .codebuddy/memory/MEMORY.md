# 项目长期记忆（MEMORY.md）

> 华为 MateBook D15（BoF-XX）/ es8336 + HWSP0001 功放，用户空间修复项目。

## 稳定事实 / 坑

- **SOF 固件 IPC 超时是反复出现的固件级问题**：`dmesg` 刷 `sof-audio-pci-intel-tgl ... IPC timeout` / `pcm0 (ES8336) STREAM_PCM_PARAMS ipc failed` / `ASoC error (-110)`，导致 ES8336 pcm0 的 hw_params 失败、扬声器+耳机**都没声**（两者共用 pcm0）。曾靠内核 6.18.48-amd64-desktop-rolling 缓解，但**未根除**，长时间运行后仍可能 wedged（实测开机约 17h 后自发复发）。恢复手段：重启，或停 PipeWire 后 `modprobe -r/modprobe` 重载 sof 模块（繁琐有风险）。
- **耳机麦路由修复**：es8336 `Differential Mux` 应为 `lin2-rin2`（UCM 默认 `lin1-rin1` 会静音耳机麦），并保 `Digital Mic Mux='dmic disable'`。已集成进 `huawei-speaker-mute.sh` 的 `set_hp_mic_route()`（开机+插耳机两处调用）。控件是非 simple control，须用 `amixer cget/cset`，`scontrols` 查不到。
- **install.sh 预存 bug（已修）**：服务模板 ExecStart 写死 `/opt`，sed 却匹配 `/usr/local/bin` → 服务一直跑旧脚本。已改为整行替换 `^ExecStart=.*`，模板改指 `/usr/local/bin`。
- **系统 /usr 只读（ostree/不可变风格）**：`/usr/share/alsa/ucm2` 等 /usr 下路径不可写（install.sh 编辑 UCM 时报 "只读文件系统"）。因此 UCM 文件级修正无法持久化，耳机麦路由只能靠运行期 `huawei-speaker-mute.sh` 的 `set_hp_mic_route()` 兜底；但 `/etc` 可写，`/etc/modprobe.d/sof-es8336-nodmic.conf`（拓扑参数）可正常落地，重启生效。
- **🚫 禁止强制无 DMIC 拓扑（实测会毁音频）**：用 `snd_sof.tplg_filename=sof-adl-es8336-ssp0.tplg` 去掉 DMIC 后，开机"没有音频设备"。机制：卡片 `alsa.components` 仍含 `cfg-dmics:2`（来自 NHLT，与拓扑无关），UCM 的 HiFi verb 仍引用 `hw:0,1`，而无 DMIC 拓扑已无 `hw:0,1` → HiFi profile 丢失，`pactl` 只剩 `off`/`pro-audio`，WirePlumber 只剩 `null-sink`。但 ALSA 层 `aplay -D hw:0,0` 其实正常。**结论：无 DMIC 拓扑与仍广播 DMIC 的 NHLT/UCM 不兼容，此路不通。** install.sh 中该项已改为默认关闭（仅 `FORCE_NODMIC_TOPO=1` 才应用）。回滚：`sudo rm /etc/modprobe.d/sof-es8336-nodmic.conf` + 重启。
- **文档已整理进 `doc/`**：FORUM_POST / JACK_RECOVERY_DESIGN / REFACTOR_PLAN / HEADSET_MIC_ROUTING / UCM_AUDIT_2026-09-10 / DEPLOY_AUDIO_HARDENING / **AUDIO_SILENCE_ANALYSIS（失声分析与方案）**。刻意不提交 `kernel/backup/*`。
- **HWSP0001 扬声器功放**：I2C 总线 4、地址 `0x58`/`0x5B`，**只驱动扬声器**（耳机走 ES8336 独立路径）。软静音寄存器 `0x01`：写 `0x00` = **仅静音扬声器**（耳机照常响），写 `0x69` = 恢复。这是本项目用户空间修复的核心。
- **gpio-81（ESSX GpioInt）电平恒定**：是脉冲/边沿中断线，**不能**用电平做插拔检测（2026-07-27 与 2026-09-10 两次实测均恒定）。
- **codec 寄存器 `0x4F` 可作 jack 状态源**：经 regmap debugfs 读（`/sys/kernel/debug/regmap/i2c-ESSX8336:00/registers`，走 regmap 锁、安全、无需裸 i2cget）——插入 `0x20`、拔出 `0x24`、带麦 `0x22`。注意：codec deep-shutdown 时该值也会冻结。
- **用户空间修复与内核无关**：无任何自定义内核模块/内核配置改动，`git diff` 仅脚本 + 文档，可即时回退、零残留。
- **早期"驱动补丁"方向已作废**：曾按 LKML `sof_es8336` headphone GPIO 反相补丁编译 `JD_INVERTED`；后经 `objdump` 反汇编确认**发行版原版已是取反版**（`gpio_headphone = !speaker_en`），该方向无效。jack 冻结真因见 `kernel/backup/README.md` 与 `doc/JACK_RECOVERY_DESIGN.zh-CN.md`（codec JD 掉电 deep shutdown + 中断仅电平触发）。

## 硬件与器件（稳定）
- codec：ES8336（驱动 es8316），I2C2，双地址 `0x10`/`0x11`；dmesg `assuming static mclk`。jack 中断 = ACPI `GpioInt(Edge, ActiveBoth)`（gpio-81）。
- 功放：HWSP0001（同上）；`/etc/modprobe.d/sof-es8336.conf` 设 `quirk=0xA0`（= DMIC + headphone GPIO，**不含 JD_INVERTED**）。
- **扬声器与耳机共用 pcm0**（ES8336 device 0）；HDMI 为 device 5/6/7（独立 PCM）。故"两个一起哑"必然是公共路径问题。
- 系统 `/usr` 只读（ostree/不可变风格）。

## 上游来源 / 署名
- 项目**初始代码来自 [MaximushkaBed/huawei-matebook-d15-speaker-fix](https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix)**；用户在其基础上适配优化（修复"插耳机扬声器不静音"、补自动探测/防爆音/内核无关性验证/文档）。发布时须保留对 MaximushkaBed 的署名。

## 脚本定位（可移植性）
- `huawei-speaker-mute.sh` 是 **HWSP0001 成品修复，非通用工具**：`detect_i2c`（`i2c-HWSP0001:00`）、`set_amp` 的寄存器/地址、DSDT `GNUM()` GPIO 解析均为本机专属。
- 可复用框架（硬件无关）：监听插拔事件 + 功放软静音 + 音量保护 + systemd 常驻。
- 移植条件：功放 I2C 可达且有软静音寄存器；耳机路径独立于功放；存在可监听的插拔源。

## 用户环境
- 用户 dp25；系统滚动内核 6.18.48；git 双远端 gitee(xiyidaiwa) / github(testerxydw)。
- 部署路径：脚本装到 `/usr/local/bin/huawei-speaker-mute.sh`，服务 `/etc/systemd/system/huawei-speaker-mute.service`。
