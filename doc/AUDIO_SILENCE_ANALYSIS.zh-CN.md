# 音频失声（用一段时间 / 系统休眠后）分析与排查方案

> 日期：2026-09-10。状态：**分析 + 取证中**；已应用一项缓解（禁止 PipeWire 空闲挂起）。
> 目标：定位"使用一段时间后耳机 + 扬声器**同时**失声"的根因并给出方案。
> 关联：`huawei-speaker-mute.sh`（插拔联动，与本故障正交）。

---

## 1. 问题陈述

- **现象**：正常使用一段时间后，**扬声器与耳机同时无声**；桌面音频图标**正常**，**可正常切换**耳机/扬声器/HDMI。
- **恢复**：`systemctl --user restart wireplumber pipewire pipewire-pulse`（**整栈重启**）**偶尔能恢复、偶尔不能**。
- **重要线索（用户实测）**：**多次是在系统休眠（S3）之后出现**。
- **边界**：jack 卡死极少、可忽略。本项目早期的"防僵死 debounce / health_check / jack 死亡告警"已被重构移除，用户明确**不再移植**（加了反而使 jack 卡死更严重）。

---

## 2. 已核实事实（2026-09-10）

- 扬声器与耳机**共用 pcm0（ES8336 codec）**：`card0 sofessx8336` 的 `device 0` 同时是两者通路；HDMI 是 `device 5/6/7`（独立 PCM）。→ 任何"两个一起哑"必然是**公共路径**问题。
- 失声时 **PipeWire/WirePlumber 层健康**（sink 存在、端口可切）→ **排除路由层**；故障在 pcm0 公共路径。
- 栈版本：PipeWire `1.6.4`、WirePlumber `0.5.14`（deepin 打包）。
- **WirePlumber 空闲挂起机制（源码实锤）**：`/usr/share/wireplumber/scripts/node/suspend-node.lua` —— 节点进入 `idle`/`error` 后，按 `session.suspend-timeout-seconds`（**默认 5 秒**）执行 `node:send_command("Suspend")`（关闭 PCM）；该值 `=0` 则**永不挂起**（脚本第 43–45 行 `if timeout == 0 then return end`）。
- ACPI 支持 S0/S3/S4/S5。
- codec：ES8336（驱动 es8316），dmesg `assuming static mclk`；jack 用 es8316 IRQ（与本故障无关）。
- SOF：固件 `sof-adl.ri` 版本 `2:2:0-57864`，**Firmware ABI 3:22:1 / Kernel ABI 3:23:1（不匹配，固件偏旧）**；拓扑 `sof-adl-es8336-dmic2ch-ssp0.tplg`；IPC3。
- 机器驱动 `snd_soc_sof_es8336` 用 `.pm = &snd_soc_pm_ops`（走 ASoC 的 suspend/resume 路径）。

---

## 3. 假设（按可能性排序）

| 编号 | 假设 | 说明 | 判别特征 |
|------|------|------|----------|
| **H1（主）** | **S3 唤醒后 SOF DSP / codec 未正确恢复** | ASoC/SOF resume 或 codec `regcache_sync` 失败 → pcm0 不可用 → 两个都哑；重开 PCM（整栈重启）有时能重新初始化 | 失声前有休眠；resume 附近 dmesg 有 sof/es8316 异常 |
| H2 | PipeWire 空闲挂起→resume 抖动 | 与 H1 同类、更轻量；空闲 5s 关 PCM、下次再开 | 空闲后首次播放失声 |
| H3 | SOF DSP 固件 wedge（`ipc timeout`/`-110`） | 既有"约 17h 自发复发"问题 | dmesg 刷 `sof...ipc timeout`；整栈重启**无效** |

**决定性判别**：
1. 失声瞬间 `dmesg` 是否出现 `sof...ipc timeout` / `ASoC error (-110)`；
2. 失声时 **HDMI 是否有声** —— 有声 → 仅 ES8336 路（偏 H1/H2）；也哑 → DSP 全局（偏 H3）。

---

## 4. 已做的动作

- ✅ **禁止 PipeWire 空闲挂起**（缓解 H2）：
  - **固化于本项目**：`config/wireplumber/51-sof-essx8336-nosuspend.conf`（**文件头 `##` 注释内含恢复方式**）。
  - 部署位置（由 `install.sh` 的 `apply_wireplumber_nosuspend()` 安装到桌面用户）：
    `~/.config/wireplumber/wireplumber.conf.d/51-sof-essx8336-nosuspend.conf`
    ```
    monitor.alsa.rules = [
      {
        matches = [ { node.name = "~alsa_.*sof-essx8336.*" } ]
        actions = { update-props = { session.suspend-timeout-seconds = 0 } }
      }
    ]
    ```
  - 应用：`systemctl --user restart wireplumber`；**已验证** sink 节点 `session.suspend-timeout-seconds = "0"`（带注释部署亦生效）。
  - **恢复/回滚**：
    `rm -f ~/.config/wireplumber/wireplumber.conf.d/51-sof-essx8336-nosuspend.conf && systemctl --user restart wireplumber`
  - **跳过安装**：`SKIP_WP_NOSUSPEND=1 sudo bash install.sh`（可用 `DESKTOP_USER=<用户>` 指定目标用户）。
- ✅ **取证器**：`/tmp/audio_health.sh` → 日志 `/tmp/audio_health.log`
  - 每 20s 快照：`pcm0p` 状态 / jack / codec `0x4f` / 功放 `0x58` / 默认 sink；
  - 后台 `sudo dmesg -w` 抓 `sof|ipc|es8316|jack|timeout`。
  - 停止：`pkill -f audio_health.sh`。

---

## 5. 后续排查方式（复发时执行）

1. **报时间** → 读 `/tmp/audio_health.log`，比较失声前后 `sink / pcm0p / dmesg` 变化。
2. **失声瞬间一次性取证**：
   ```bash
   wpctl status | sed -n '/Sinks:/,/Sources:/p'
   cat /proc/asound/card0/pcm0p/sub0/status
   sudo dmesg -T | grep -iE 'sof|ipc|es8316|snd|-110|timeout|PM: suspend|PM: resume' | tail -40
   amixer -c0 cget numid=27 | grep -i values
   amixer -c0 cget name='Speaker Switch' | grep -i values
   amixer -c0 cget name='Headphone Switch' | grep -i values
   sudo i2cget -y -f 4 0x58 0x01
   ```
3. **失声时切 HDMI 试听**（决定性：区分"仅 ES8336 路" vs "DSP 全局"）。
4. **专项复现休眠**：休眠 → 唤醒后立刻看 dmesg `PM: suspend entry/exit` 附近有无 sof/es8316 报错，并试播放。

---

## 6. 方案（候选，按风险从低到高）

| 编号 | 方案 | 风险 | 说明 |
|------|------|------|------|
| **S1** | 禁止 PipeWire 空闲挂起 | 低（可回退） | **已应用**。减少空闲 PCM 反复开关。 |
| **S2** | **休眠恢复钩子自动重启音频栈** | 低（可回退） | `/usr/lib/systemd/system-sleep/` 脚本在 `post suspend` 时以桌面用户身份执行 `systemctl --user restart wireplumber pipewire pipewire-pulse`（复用用户现有 restart 脚本逻辑）。因"手动重启多数能恢复"，可在**唤醒后立即自愈**。治标，但对"休眠后失声"命中率高。 |
| **S3** | 关闭相关运行时节能 / DSP 低功耗 | 中 | 减少 D3/resume 复杂度，需确认 `snd_sof` 等参数，谨慎。 |
| **S4** | 更新 `linux-firmware` / 内核 | 高（周期长） | 拿 ABI 匹配的 `sof-adl.ri`；或针对 SOF S3-resume 的驱动修复。**唯一根治方向**。 |

**明确不做**：① 无 DMIC 拓扑（已证破坏 UCM、开机无音频设备）；② 移植旧的 jack 防僵死逻辑（用户已否决）。

---

## 7. 回滚

- **S1**：删除 `~/.config/wireplumber/wireplumber.conf.d/51-sof-essx8336-nosuspend.conf` + `systemctl --user restart wireplumber`。
- **S2**（若实施）：删除对应 `/usr/lib/systemd/system-sleep/` 脚本即回退。
- 以上均不涉及内核/驱动，回退零残留。
