# Jack 检测软恢复设计（新需求，待验证）

> 状态：**设计草案，核心可行性未验证，禁止据此写恢复代码**。
> 适用机型：Huawei MateBook BoF-XX（本机 `NEEDS_GPIO=0`，BIOS/ACPI 独占功放 GPIO）。
> 关联：本项目 `huawei-speaker-mute.sh` 依赖 jack 检测做插拔联动静音/恢复。

---

## 1. 问题定义

耳机插拔 jack 检测在运行期会"死"：内核不再发出 `SW_HEADPHONE_INSERT` 事件，`ALSA` 的 `Headphone Jack`(numid=27) / `Headset Mic Jack`(numid=28) 控件卡死，导致脚本无法联动静音/恢复。

用户诉求：**不靠整机重启恢复**（这正是本项目的初衷）。

### 1.1 已实测排除的原因（不要再往这方向查）
- **脚本 / R2 / R6 改动无关**：回退到纯 R6 后，独立的每 2s ALSA 采样进程全程 `jack=on` 无跳变。
- **PipeWire 重启无效**：PipeWire 只是 jack 控件的消费者，不产出/修改插拔状态。
- 两个 ALSA jack 控件**同时**卡死（27=on、28=off 均不随插拔翻转），不是"换个控件监控"能解决。

### 1.2 已实测确认的事实
- 死态下 `python3` 直读 `/dev/input/event10` 原始字节 25s 窗口：**零 `SW_HEADPHONE_INSERT` 事件** → 内核 input 子系统层就无事件。
- 尝试"软重载声卡"失败：内核 SOF 驱动 probe 时申请 `speakers-enable` / `headphone-enable` GPIO 得到 `EBUSY`（`gpioinfo` 看不到占用者 → 冲突在 **ACPI/固件层**），`card0` 注册失败，声卡消失。**当前本机 `no soundcards`，需整机重启恢复**。

### 1.3 运行期死亡的根因（开放问题，见 §4 Q2）
dmesg 启动期有 `sof ... ipc tx error -5`（SOF 固件 IPC 失败）。jack 检测在 07:44–11:22 正常，之后静默。最可能：SOF 固件/IPC 运行期不稳导致整条声卡检测链路失效。**但 GPIO EBUSY 是我们"重载"时才暴露的，不是原始死亡的原因**——两件事实要分开。

---

## 2. 需求拆解

### 2.1 死亡侦测（watchdog）
判定"jack 检测已死"的信号，需低误报：
- 候选 A：内核 input 事件**静默超时**（监听进程在 M 秒内未收到任何 SW 事件，且期间有主动插拔 attempted）——但正常静置也无事件，需配合"应有跳变却无"。
- 候选 B：`card0` 消失 / `SOF IPC` 错误计数骤增（可从 `dmesg` 或 `/proc/asound` 探测）。
- 候选 C：脚本 `jack_monitor` 主通道退出 + `alsactl` 次通道退出 + 2s 兜底也读不到跳变，持续 N 个周期。
- **建议**：B + C 组合作为"死亡"判据（card 消失或主/次/兜底三级全失效且静默超时），避免单纯"长时间不变"误判。

### 2.2 软恢复原语（recovery primitive）—— 核心未知
| 候选 | 做法 | 可行性 | 状态 |
|------|------|--------|------|
| P1 模块重载 | `modprobe -r/modprobe snd_soc_sof_es8336` | ❌ 已证伪：GPIO EBUSY 阻塞 | 排除 |
| P2 PCI 设备 sysfs 重绑 | `echo 1 > /sys/bus/pci/devices/0000:00:1f.3/remove` 后 `rescan`，强制整设备断电再上电，可能释放 ACPI GPIO | ❌ **已证伪（2026-08-17 14:35 Q1 实验）**：remove 后 `no soundcards`，rescan 后 card0 仍无，dmesg 报 `headphone-enable GPIO EBUSY`（error -16），与 P1 同源 | 排除 |
| P3 DSDT / 驱动补丁 | 让 SOF/es8336 驱动**不申请** `speakers/headphone-enable` GPIO（改由 BIOS 独占），消除 EBUSY → 使 P1/P2 可用；可能顺带稳定 jack 检测 | ⚠️ 重：需自定义内核模块/ACPI 表、签名、随内核更新维护 | 候选（针对"重载阻塞"，未必治本） |
| P4 替代检测源 | 绕开死的 ALSA 控件，找其它插拔信号：codec JD 引脚（debugfs）、或用户态读 GPIO（若 ACPI 允许 `gpiod` 读） | ❓ 未验证；BoF-XX 上 GPIO 被 ACPI 独占，gpiod 大概率读不到 | **需实验** |
| P5 接受仅能重启 | watchdog 改为告警 + 可选自动重启 | ✅ 可行但与"避免重启"诉求冲突 | 降级兜底 |

> **关键**：P3（驱动补丁）解决的是"重载恢复被 GPIO EBUSY 阻塞"，**不保证能阻止运行期 jack 死亡**（§1.3）。若目标是"永不死"，P3 可能只是让"死后能软恢复"成为可能，仍需 P2 验证软恢复能否成功。

---

## 3. 设计结构（门控，未验证前不实现）

```
[watchdog 循环]
   ├─ 死亡判据(B+C) 满足？
   │     ├─ 否 → 继续监控
   │     └─ 是 → 触发 recovery primitive
   │               ├─ P2 PCI 重绑（优先试，最轻）
   │               ├─ 失败 → P3 前提缺失，回退 P5 告警/自动重启
   │               └─ 成功后校验 card0 回来 + jack 能翻转
   └─ 恢复后：重启本脚本监听通道（不重启整机）
```

- watchdog 不应与现有 `health_check`（I2C 寄存器级自愈）混淆：前者管"声卡/jack 检测栈"，后者管"功放寄存器值"。
- 恢复动作必须**可回退**：任何软恢复失败都不能比"现状更糟"（本次实验已证明重载失败会让声卡消失——必须先把 P2 验证为安全再纳入）。

---

## 4. 实现前必须回答的开放问题

- **Q1（P2 可行性）**：`PCI remove/rescan` 在 BoF-XX 上能否恢复 `card0` 且不 EBUSY？→ 需重启后做一次性实验。
- **Q2（死亡根因）**：运行期 jack 死亡由什么触发（suspend/resume？某应用？SOF IPC 累积错误？）→ 决定 P4 替代源是否必要、P3 是否治本。建议在"正常可检测"状态下长期抓取 `dmesg | grep sof` 与 input 事件，定位死亡瞬间。
- **Q3（兜底接受度）**：若仅 P5 可行，是否接受"自动重启"作为最后兜底（与避免重启诉求冲突，需用户拍板）。

---

## 5. 当前阻塞与下一步

1. **立即**：整机重启恢复音频（本次重载实验所致 `no soundcards`）。
2. 重启后第一时间复测：`amixer -c 0 cget numid=27` 插拔是否翻转，确认 jack 回到"开机正常"。
3. 做 **Q1 实验**：在 jack 正常态下，跑 P2（PCI remove/rescan），验证能否软恢复且不 EBUSY。**这是决定本需求能否成立的关键实验。**
4. Q1 通过 → 写 watchdog + P2 恢复（最小实现，复用现有 `health_check` 框架风格）；Q1 失败 → 评估 P3（重）或 P5（兜底）。

> 本设计仅作规划。在 Q1/Q2 未回答前，不得编写恢复代码。

---

## 7. Q1 实验结果（2026-08-17 14:35）

- **做法**：停 pipewire + 禁 socket（/dev/snd 占用=0）→ PCI `remove` 0000:00:1f.3 → `rescan`。
- **结果**：`remove` 后 `no soundcards`；`rescan` 后 **card0 仍无**；dmesg 报 `sof-essx8336: error -EBUSY: could not get headphone-enable GPIO`（error -16）。
- **结论**：`headphone-enable` / `speakers-enable` GPIO 被 **ACPI/BIOS 持久独占**，既不被模块卸载释放、也不被 PCI 重枚举释放。任何"内核态 reload 驱动"路径（P1/P2）都**无法**软恢复声卡。
- **唯一能恢复的手段**：整机重启（重启重新初始化 ACPI，驱动重新拿到 GPIO）。
- **对需求的影响**：jack 检测软恢复**不能靠驱动重载实现**；剩余可行路径仅：
  - **P3（重）**：DSDT override / 内核 SOF 驱动补丁，让驱动**不申请**这批 GPIO（改由 BIOS 独占），从而消除 EBUSY——可能使 P1/P2 类重载可行，但工作量重、需随内核更新维护，且**不保证能阻止运行期 jack 死亡**（§1.3）。
  - **P4（待验）**：替代检测源（codec JD 引脚 debugfs / 用户态读 GPIO），绕过死的 ALSA 控件；但 BoF-XX ACPI 独占 GPIO，gpiod 大概率读不到，待验。
  - **P5（兜底）**：接受"仅能整机重启"，watchdog 改为告警/自动重启——与"避免重启"诉求冲突。
- **当前状态**：声卡因本实验再次消失（`no soundcards`），需用户整机重启恢复。在 P3/P4 未验证前，**禁止再尝试任何内核态重载**（必致声卡消失且需重启）。

---

## 6. 重启后已知现象与相邻问题（非本需求范畴，记录备查）

### 6.1 重启后 jack 检测已恢复（关键确认）
- 重启后 `amixer -c 0 cget numid=27` 在插拔时正常 `on↔off` 翻转 → 印证"运行期死亡"是临时态，**随重启恢复**，非永久硬件故障。
- 结论：jack 检测软恢复（本需求）只在"运行期死亡"时才有意义；日常多数时间 jack 正常。

### 6.2 相邻问题 1：开机首次拔耳机偶发切到 HDMI 输出
- **根因**：WirePlumber 默认路由策略（`module-policy-node` 的 follow/回退），非本脚本行为。开机时扬声器 sink 尚未就绪（PipeWire 晚于声卡/脚本启动），WirePlumber 临时把"拔出→默认路由"落到 HDMI sink；手动切回扬声器后偏好稳定，后续不再跳 HDMI。
- **脚本无关**：本脚本只动功放 I2C 静音 + 音量保护，**不改变 PipeWire sink 路由**。
- **归属**：PipeWire/WirePlumber 配置问题（固定默认 sink 为扬声器、关闭自动跟随 HDMI），不属于"jack 检测软恢复"需求。

### 6.3 相邻问题 2：拔插耳机时"音量设 0"有时间延迟
- **根因**：`unplug_volume_guard`（含已提交的 R6）在 `on→off` 跳变瞬间做 3 次 `wpctl set-volume 0` + 各 0.25s 间隔，**总延迟约 0.75s**。
- 该延迟是**故意保留**的防爆音机制：用来压过 WirePlumber 在 jack 事件后"按端口恢复音量"的竞态（否则音量会被调回，防爆音失败）。属必要代价，非 bug。
- R6 只把 3 次 runuser 会话合并为 1 次（消除 PAM 抖动），**总时长不变**，与此延迟无关。
- 若体感过长，可考虑降到 2 次或缩短间隔，但须实测防爆音仍成立。
- **归属**：音量保护策略调优，独立于本需求；可在 R6 之后单独评估，不阻塞 jack 软恢复设计。

### 6.4 关于手动采样出现的 `on/on/off` 连续状态
- 用户实测末尾出现两次连续 `on` 再 `off`：经澄清，**这是手动采样时序，非 jack 抖动**。用户两次都是在"插入耳机后"才敲 `amixer` 查看，故先看到一串 `on`，拔出后才翻 `off`；中间 `on/off` 交替同理（插着看一次、拔了看一次）。
- 结论：**jack 检测当前完全正常，不存在内核抖动**。脚本 `jack_monitor` 主通道是实时监听，不受手动查看节奏影响，无需特殊处理。本条仅为澄清误判，不作为问题记录。

---

## 8. 死亡告警（已实施，不依赖软恢复）

> 由于软恢复（P1–P4）均不可行/未验证，唯一恢复手段是整机重启。
> 但在"运行期死亡 → 用户发现 → 手动重启"这段窗口里，插拔联动静音完全失效，
> 用户可能很久才发现。因此新增**系统级告警**，让用户在几十秒内察觉 jack 已死。

### 8.1 告警触发点
- 复用现有 `health_check`（每 `HEALTH_CHECK_INTERVAL`=60s 一次）：
  - `check_jack_detection`（设备级存活）判定事件设备**不可读**时，认为 jack 联动已失效。
  - **去重**：`JACK_ALERT_RAISED` 标志，已告警则不再刷屏；设备恢复可读后自动重置，下次死亡可重新告警。
- `status` 子命令仅做只读报告，**不触发**弹窗（避免手动查状态误弹)。

### 8.2 告警通道（多层级兜底，2026-08-17 实测全部生效）
1. **桌面通知（首选，critical 级）**：以桌面用户身份（`runuser -u <user>` + `DISPLAY`/`DBUS_SESSION_BUS_ADDRESS` 注入）调 `notify-send -u critical`。自动探测桌面用户（优先 `PW_USER`，否则扫描 `/run/user/*` 持有 `dbus-1`/`bus` socket 的用户）。
2. **`wall` 广播**：发给所有登录 TTY（不依赖桌面环境，本机 tty1 必收）。
3. **`logger -t huawei-speaker-mute -p user.crit`**：写入系统日志（`journalctl` 持久可查）。

### 8.3 环境适配
- 本机：`XDG_SESSION_TYPE=x11`、用户 `dp25`(uid 1000)、`DISPLAY=:0`、`notify-send`/`zenity`/`dbus-send`/`wall` 均可用。
- 无图形会话（纯服务器/SSH）：第①层自动跳过，仍由 `wall` + `logger` 兜底。
- 注意：脚本以 root（systemd service）运行，桌面属于普通用户，弹窗必须经过该用户的 DBus 会话，不能由 root 直接 `notify-send`。
