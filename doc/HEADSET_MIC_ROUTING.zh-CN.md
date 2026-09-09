# 耳机麦克风路由修复（es8316 Differential Mux）

> 关联：`huawei-speaker-mute.sh`（扬声器/耳机插拔联动）已把本修复集成进去。
> 本文记录问题定位、根因与验证结论。

## 1. 现象

插上带麦耳机后，系统能识别 `Headset` 输入源，但录音全零/静音；内置 DMIC 正常（RMS ~43）。
`hw:0,0`（模拟通路）能采到数据但**全是零**——编解码器 ADC 有数据流，但模拟输入没有信号。

## 2. 根因

本机编解码器为 ES8336（声卡 `sofessx8336`，card 0）。耳机麦的模拟信号实际接到差分输入对
`lin2-rin2`（Mux=1），而 UCM/驱动默认把 `Differential Mux` 设为 `lin1-rin1`（Mux=0），导致
ADC 采到的模拟输入没有信号。

**`Differential Mux` 控件事实（已核实）：**

- 卡号：0（`sof-essx8336`）
- 控件名：`Differential Mux` —— **非 simple control**，只能用 `amixer cget/cset` 操作，`amixer scontrols` 列表里查不到
- 枚举项：`0=lin1-rin1`、`1=lin2-rin2`、`2=lin1-rin1 with 20db Boost`、`3=lin2-rin2 with 20db Boost`
- 本机正确值：`1`（`lin2-rin2`）
- 关联控件：`Digital Mic Mux` 须为 `dmic disable`（其余值会静音耳机麦；该值不影响 DMIC 本身）

> 注：早年另有一类"所有采集无数据"的问题，根因是 SOF 固件 IPC 超时（固件级），由新内核
> `6.18.48` 修复，与本次路由问题无关。

## 3. 验证方法（能量扫描）

依次把 `Differential Mux` 设为每个枚举值，从 `hw:0,0` 抓 0.3s 原始音频算 RMS/峰值，有信号者
即为正确路由。本机实测：

| Mux | 结果 |
|-----|------|
| 0 = lin1-rin1（UCM 默认） | ❌ 静音 |
| **1 = lin2-rin2** | ✅ 峰值 8448 / RMS 1534（强信号） |
| 2、3（带 20dB 增益） | ❌ 静音 |

结论：耳机麦信号稳定落在 `lin2-rin2`，与耳机型号/重启无关（孔的麦触点物理锁定到该差分对）。

## 4. 修复（已集成进 huawei-speaker-mute.sh）

新增 `set_hp_mic_route()`，在两处调用：

- **开机启动**：服务 `After=pipewire.service`，在 UCM 之后执行 → 覆盖开机阶段对 `alsa-store` 的重置；
- **插耳机事件**：在 `set_amp 0`（扬声器静音）之后调用 → 覆盖插拔瞬间 PipeWire/UCM 的路由重置。

控件探测改用 `amixer cget`（非 scontrols，因该控件非 simple）；控件不存在时静默跳过，
**不影响功放静音核心功能**。正确值由环境变量 `HP_MIC_DIFF_MUX` 控制，默认 `lin2-rin2`
（本机验证值），其他机型可覆盖。

## 5. 持久化（两层纵深防御）

1. **静态层**：`alsactl store` 把 `lin2-rin2` 写入 `/var/lib/alsa/asound.state`，alsa-restore 开机恢复；
2. **动态层**：本 daemon 在开机/插拔时强制重设，作为 UCM 覆盖 `alsa-store` 的兜底。

## 6. 适用范围

- **单机型（本机）**：路由固定为 `lin2-rin2`，当前方案已覆盖基本使用场景，无需额外标定。
- **多机型通用化**：若要把项目做成通用工具，应改为"开机/首次插拔时能量扫描自标定 + 缓存结果"
  （`huawei-mic-calibrate`），避免把 `lin2-rin2` 强加给接 `lin1-rin1` 的板号变体。

## 7. 验证与回退

```bash
# 当前路由应为 lin2-rin2（values=1）
amixer -c0 cget name='Differential Mux'

# 服务日志应出现：
#   耳机麦路由：Differential Mux='lin2-rin2' (声卡=0)
systemctl status huawei-speaker-mute.service
```

回退：停止服务即不再强制路由；如需改回静态值，用 `alsactl store`/`alsactl restore` 调整。
