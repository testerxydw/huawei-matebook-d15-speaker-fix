# 项目长期记忆（MEMORY.md）

> 华为 MateBook D15（BoF-XX）/ es8336 + HWSP0001 功放，用户空间修复项目。

## 稳定事实 / 坑

- **SOF 固件 IPC 超时是反复出现的固件级问题**：`dmesg` 刷 `sof-audio-pci-intel-tgl ... IPC timeout` / `pcm0 (ES8336) STREAM_PCM_PARAMS ipc failed` / `ASoC error (-110)`，导致 ES8336 pcm0 的 hw_params 失败、扬声器+耳机**都没声**（两者共用 pcm0）。曾靠内核 6.18.48-amd64-desktop-rolling 缓解，但**未根除**，长时间运行后仍可能 wedged（实测开机约 17h 后自发复发）。恢复手段：重启，或停 PipeWire 后 `modprobe -r/modprobe` 重载 sof 模块（繁琐有风险）。
- **耳机麦路由修复**：es8336 `Differential Mux` 应为 `lin2-rin2`（UCM 默认 `lin1-rin1` 会静音耳机麦），并保 `Digital Mic Mux='dmic disable'`。已集成进 `huawei-speaker-mute.sh` 的 `set_hp_mic_route()`（开机+插耳机两处调用）。控件是非 simple control，须用 `amixer cget/cset`，`scontrols` 查不到。
- **install.sh 预存 bug（已修）**：服务模板 ExecStart 写死 `/opt`，sed 却匹配 `/usr/local/bin` → 服务一直跑旧脚本。已改为整行替换 `^ExecStart=.*`，模板改指 `/usr/local/bin`。
- **系统 /usr 只读（ostree/不可变风格）**：`/usr/share/alsa/ucm2` 等 /usr 下路径不可写（install.sh 编辑 UCM 时报 "只读文件系统"）。因此 UCM 文件级修正无法持久化，耳机麦路由只能靠运行期 `huawei-speaker-mute.sh` 的 `set_hp_mic_route()` 兜底；但 `/etc` 可写，`/etc/modprobe.d/sof-es8336-nodmic.conf`（拓扑参数）可正常落地，重启生效。
- **🚫 禁止强制无 DMIC 拓扑（实测会毁音频）**：用 `snd_sof.tplg_filename=sof-adl-es8336-ssp0.tplg` 去掉 DMIC 后，开机"没有音频设备"。机制：卡片 `alsa.components` 仍含 `cfg-dmics:2`（来自 NHLT，与拓扑无关），UCM 的 HiFi verb 仍引用 `hw:0,1`，而无 DMIC 拓扑已无 `hw:0,1` → HiFi profile 丢失，`pactl` 只剩 `off`/`pro-audio`，WirePlumber 只剩 `null-sink`。但 ALSA 层 `aplay -D hw:0,0` 其实正常。**结论：无 DMIC 拓扑与仍广播 DMIC 的 NHLT/UCM 不兼容，此路不通。** install.sh 中该项已改为默认关闭（仅 `FORCE_NODMIC_TOPO=1` 才应用）。回滚：`sudo rm /etc/modprobe.d/sof-es8336-nodmic.conf` + 重启。
- **文档已整理进 `doc/`**：FORUM_POST / JACK_RECOVERY_DESIGN / REFACTOR_PLAN 及新 `doc/HEADSET_MIC_ROUTING.zh-CN.md`；README 第 8 节链接指向 `doc/`。提交 `4379bc0` 已推 gitee+github。刻意不提交 `kernel/backup/*`。

## 用户环境
- 用户 dp25；系统滚动内核 6.18.48；git 双远端 gitee(xiyidaiwa) / github(testerxydw)。
- 部署路径：脚本装到 `/usr/local/bin/huawei-speaker-mute.sh`，服务 `/etc/systemd/system/huawei-speaker-mute.service`。
