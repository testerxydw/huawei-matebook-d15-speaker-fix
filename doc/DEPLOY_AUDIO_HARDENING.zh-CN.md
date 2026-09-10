# 音频加固部署清单（防 wedge + 耳麦麦 UCM 化）

> 目标：把两件独立的、纯配置级、可逆的改动合并成一个可部署/可回滚清单。
> 1. **方案 A**：强制无 DMIC 拓扑 `sof-adl-es8336-ssp0.tplg`，切断 DMIC 触发源 → 防 SOF IPC 超时 wedge。
> 2. **UCM 修正**：在 `sof-essx8336.conf` 的 BootSequence 加 `Differential Mux=1`，让耳麦麦由 UCM 托管 → 不再依赖手写 amixer。
>
> 本文件是**部署清单（先不动）**：只列命令与回滚，由人工确认后执行。两者均不改内核/驱动、不编模块。
> 详细排查依据见 `doc/UCM_AUDIT_2026-09-10.zh-CN.md`。

## 前提（已核实）
- 拓扑文件存在：`/lib/firmware/intel/sof-tplg/sof-adl-es8336-ssp0.tplg.zst` ✅
- 编码器 ES8336 物理接在 **ssp0**（当前 topo `sof-adl-es8336-dmic2ch-ssp0.tplg` 证实）→ 必须用 **ssp0**，绝不可用 ssp1（会路由错 I2S 口 → 静音）。
- UCM 目录存在：`/usr/share/alsa/ucm2/Intel/sof-essx8336/sof-essx8336.conf`。
- `tplg_filename` 参数用**不带 `.zst` 的名字**（内核内部去掉后缀），即 `sof-adl-es8336-ssp0.tplg`。

## 改动一：UCM 耳麦麦路由（低风险，可免重启生效）

### 部署
```bash
UCM=/usr/share/alsa/ucm2/Intel/sof-essx8336/sof-essx8336.conf
# 1) 备份（回滚用）
sudo cp "$UCM" "$UCM.bak"
# 2) 在 BootSequence 内追加 Differential Mux=1（lin2-rin2，本板耳麦麦物理差分对）
sudo python3 - <<'PY'
p='/usr/share/alsa/ucm2/Intel/sof-essx8336/sof-essx8336.conf'
s=open(p).read()
if "Differential Mux" not in s:
    s=s.replace("cset \"name='Headphone Playback Volume' 100%\"",
                "cset \"name='Headphone Playback Volume' 100%\"\n\t\tcset \"name='Differential Mux' 1\"",1)
    open(p,'w').write(s)
    print("patched")
else:
    print("already patched, skip")
PY
# 3) 生效：重启音频服务或整机重启
#    （PipeWire/PulseAudio 在声卡初始化时重读 UCM；最简单是重启）
```
> 说明：本仓库 `huawei-speaker-mute.sh` 当前也通过 amixer/alsactl 设 `Differential Mux=lin2-rin2`，
> 与本条等效；UCM 化后该步骤变冗余但无害，可保留作兜底。

### 回滚
```bash
sudo mv "$UCM.bak" "$UCM"        # 恢复原 UCM
# 重启音频/整机
```

## 改动二：强制无 DMIC 拓扑（防 wedge，需重启）

> ⚠️ **Tradeoff**：内置 DMIC 麦克风将不可用（视频会议等需外置/耳麦麦）。
> ⚠️ 仅堵"DMIC 触发"这一已知 wedge 源；固件 IPC / ABI 不匹配(3:22:1 vs 3:23:1)根因未动，不保证 100% 不再出现其他触发。
> ⚠️ 对 `linux-firmware` 升级脆弱：若某次升级删掉该 `.tplg`，开机加载拓扑失败 → 整段音频丢失。建议把文件复制到稳定位置（见"加固"小节）。

### 方式一（推荐，回滚最干净）：modprobe.d
```bash
# 1) 写入模块参数
echo 'options snd_sof tplg_filename=sof-adl-es8336-ssp0.tplg' | \
  sudo tee /etc/modprobe.d/sof-es8336-nodmic.conf
# 2) 若 snd_sof 进 initramfs，同步一下（可选，保险）
sudo update-initramfs -u 2>/dev/null || true
# 3) 重启
sudo reboot
```
回滚：
```bash
sudo rm /etc/modprobe.d/sof-es8336-nodmic.conf
sudo reboot
```

### 方式二（备选）：内核命令行
```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&snd_sof.tplg_filename=sof-adl-es8336-ssp0.tplg /' /etc/default/grub
sudo update-grub
sudo reboot
```
回滚：手动编辑 `/etc/default/grub` 删掉该参数并重跑 `update-grub`，或 `grub` 高级菜单选旧项。

### 加固（规避固件升级风险，可选）
```bash
# 把拓扑复制到不被包管理覆盖的位置，并让参数指向它
sudo mkdir -p /etc/firmware/intel/sof-tplg
sudo cp /lib/firmware/intel/sof-tplg/sof-adl-es8336-ssp0.tplg.zst /etc/firmware/intel/sof-tplg/
# 改参数指向副本：
echo 'options snd_sof tplg_filename=/etc/firmware/intel/sof-tplg/sof-adl-es8336-ssp0.tplg' | \
  sudo tee /etc/modprobe.d/sof-es8336-nodmic.conf
```
> 注意：指向带路径的文件时，需确认 snd_sof 能在该路径下找到（部分加载器要求仍位于 /lib/firmware 树下）。
> 若不确定，保留方式一的默认路径即可，风险仅在"未来某次 linux-firmware 删文件"时触发。

## 验证（部署后）
```bash
# 1) 拓扑已切换（应显示 ssp0 且无 dmic）
sudo cat /sys/kernel/debug/sof/fw_profile/tplg_name
# 2) 无 DMIC 捕获设备
arecord -l            # 不应再有 card 0 device 1 的 DMIC
# 3) 耳麦麦路由已就位
amixer -c0 cget name='Differential Mux'     # 应为 : values=1
# 4) 耳麦麦有信号（接耳麦后）
#    参考 doc/HEADSET_MIC_ROUTING.zh-CN.md 的 RMS 法抓 hw:0,0 验证峰值>0
# 5) 长期观察是否还出现 IPC timeout
sudo dmesg -T | grep -i 'sof.*ipc.*timeout' | tail
```

## 回滚总览
| 改动 | 回滚命令 |
|------|----------|
| UCM 修正 | `sudo mv $UCM.bak $UCM` + 重启音频 |
| 拓扑(方式一) | `sudo rm /etc/modprobe.d/sof-es8336-nodmic.conf` + 重启 |
| 拓扑(方式二) | 编辑 `/etc/default/grub` 去掉参数 + `update-grub` + 重启 |

## 安装期自动部署（install.sh 一次性落地，非服务运行期）

> 关键架构原则：**拓扑参数是内核模块参数，仅模块加载时读一次，运行期服务无法安全更改（重载=丢设备）**。
> 因此拓扑 + UCM 修正都应在 `install.sh` 部署时**写一次开机静态配置**，而不是放进运行期服务。
> 以下函数**已落地**到 `install.sh`（函数 `apply_boot_hardening`，在 `install_deps` 之后调用）。
> **注意**：拓扑参数写在 `/etc/modprobe.d/`，只有重启后模块重新加载才生效；UCM 修正立即生效。
> 可用 `SKIP_TOPO=1` / `SKIP_UCM=1` 跳过对应项。回滚：删除 `/etc/modprobe.d/sof-es8336-nodmic.conf` + `mv $UCM.bak $UCM` + 重启。

```bash
apply_boot_hardening() {
    # 1) 强制无 DMIC 拓扑（防 wedge）。设 SKIP_TOPO=1 可跳过（保留内置 DMIC 麦）。
    if [ "${SKIP_TOPO:-0}" != "1" ] && \
       [ -f /lib/firmware/intel/sof-tplg/sof-adl-es8336-ssp0.tplg.zst ]; then
        echo 'options snd_sof tplg_filename=sof-adl-es8336-ssp0.tplg' > \
            /etc/modprobe.d/sof-es8336-nodmic.conf
    fi

    # 2) UCM 耳麦麦路由修正：BootSequence 加 Differential Mux=1（lin2-rin2）
    local UCM=/usr/share/alsa/ucm2/Intel/sof-essx8336/sof-essx8336.conf
    if [ -f "$UCM" ] && ! grep -q "Differential Mux" "$UCM"; then
        cp "$UCM" "$UCM.bak"                       # 回滚用
        python3 - "$UCM" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
if "Differential Mux" not in s:
    s=s.replace("cset \"name='Headphone Playback Volume' 100%\"",
                "cset \"name='Headphone Playback Volume' 100%\"\n\t\tcset \"name='Differential Mux' 1\"",1)
    open(p,'w').write(s)
PY
    fi
}
```
- 这两个改动都是**重启后生效**；`huawei-speaker-mute.sh` 运行时已另设 `Differential Mux=lin2-rin2`（alsactl 静态层），与 UCM 修正等效、可并存作兜底。
- 回滚：删除 `/etc/modprobe.d/sof-es8336-nodmic.conf` 并 `mv $UCM.bak $UCM`，再重启。

## 可选看门狗：检测 + 仅通知（不自动重启）

> 需求：**检测到 SOF IPC wedge 时，发一条系统通知提醒用户手动重启，且仅通知一次（每次启动内）**。
> 不自动重启（避免误重启丢工作）。这由运行期服务 `huawei-speaker-mute.service` 的监控循环负责——
> 这是服务**唯一能增值**的环节（拓扑本身它管不了）。

### 设计要点
- 检测源：扫描内核日志中 `sof.*ipc.*timeout` / `ipc failed` / `ASoC error (-110)`。
- 通知频控：用 `/run/sof-wedge-notified`（重启即清空）做哨兵，保证**每次启动只通知一次**；用户手动重启后若再 wedge 会再次通知。
- 通知方式：`notify-send`，需把通知发到**登录用户的 DBUS 会话**（服务多以 root 运行，必须显式指定 `DBUS_SESSION_BUS_ADDRESS`）。
- 运行位置：挂进现有 `health_check` 循环（或独立低频循环），只读 dmesg，无副作用。

### `huawei-speaker-mute.sh` 已实现（**已落地**）
```bash
WEDGE_NOTIFY=${WEDGE_NOTIFY:-1}               # 默认开；设为 0 关闭
WEDGE_NOTIFY_FLAG=/run/sof-wedge-notified

notify_user() {                              # 找到登录用户的 DBUS 会话再发通知
    local title="$1" body="$2" uid bus user
    for p in /run/user/*; do
        uid=${p##*/}; [ "$uid" -gt 0 ] 2>/dev/null || continue
        bus="$p/bus"; user=$(id -nu "$uid" 2>/dev/null) || continue
        sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            DISPLAY=:0 notify-send -u critical "$title" "$body" 2>/dev/null && break
    done
}

wedge_watchdog() {
    [ "$WEDGE_NOTIFY" = "1" ] || return 0
    [ -e "$WEDGE_NOTIFY_FLAG" ] && return 0   # 本次启动已通知过
    if dmesg 2>/dev/null | grep -qE 'sof[-_].*(ipc.*timeout|ipc failed)|ASoC error \(-110\)'; then
        touch "$WEDGE_NOTIFY_FLAG"
        notify_user "音频固件卡死" \
            "检测到 SOF IPC 超时，音频已失效。请手动重启系统以恢复声音。"
    fi
}
# 在 health_check 循环里调用： wedge_watchdog
```
- `dmesg` 受限时退化为 `journalctl -k -b 0` 或读 `/dev/kmsg`（需 root，服务通常满足）。
- 该看门狗是**兜底**：若"方案 A 无 DMIC 拓扑"已把 wedge 防住，看门狗基本不会被触发。

## 结论
- 两处改动均为**纯文本/配置级、可独立回滚**，适合纳入本项目作为"音频加固"标准操作。
- 生命周期分工：**拓扑参数 + UCM 修正 = `install.sh` 一次性开机配置（非服务）**；**检测 + 通知 = 运行期服务的看门狗（仅通知、不重启）**。
- 它们解决两个维度：拓扑保"稳定不 wedge"，UCM 保"耳麦麦开箱即用"，看门狗保"出问题时用户知情"。
- **不算根治**：固件/IPC 层根因未动；真要根治仍需更新 `linux-firmware`(拿 ABI 3:23:1 匹配固件)或更新 rolling 内核。本方案是低风险、立即可做的缓解 + 体验补全。
