#!/bin/bash
# 华为 MateBook 扬声器功放（HWSP0001）插拔耳机自动静音/切换修复脚本
#
# HWSP0001 功放没有 Linux 驱动。部分机型（如 BOD-WXX9）BIOS 会在开机时通过
# SMM 初始化一次功放；但另一些机型（如 BoF-XX）会把功放留在默认的“静音”状态。
# Linux 既无法在插入耳机时把功放静音，也无法在 GPIO 断电后重新初始化它。
# 本脚本监听 ALSA 的“Headphone Jack”控件，切换功放使能 GPIO，并在功放重新
# 上电时通过 I2C 回放功放的“使能”寄存器值。
#
# 关键参数均在运行时自动探测：
#   * I2C 总线       ：来自 /sys/bus/i2c/devices/i2c-HWSP0001:00
#   * Jack 控件 numid：来自 ALSA 的 “Headphone Jack” 控件
#   * GPIO 线号      ：由 DSDT 中 HWSP 的 _INI 的 GNUM() 参数解析得到
#                      （通过 iasl 反汇编），失败时回退到下面的 GPIO_LINE
#   * 扬声器音量控件 ：来自 “DAC / Speaker / Master Playback Volume”
#
# 安全特性：当“拔掉耳机”时（jack on -> off），扬声器音量会被强制设为 0
# （通过 PipeWire，因为它在本机上拥有音量控制权），这样重新上电的功放就不会
# 以之前耳机的音量突然炸响。用户随后可手动调大音量。插入耳机 / 开机时音量
# 保持不变。

# ---------- 可配置项（可用环境变量覆盖） ----------
GPIOCHIP=${GPIOCHIP:-gpiochip0}
GPIO_LINE=${GPIO_LINE:-}          # 留空 -> 通过 DSDT(iasl) 自动探测，否则用 145
JACK_NUMID=${JACK_NUMID:-}        # 留空 -> 从 “Headphone Jack” 自动探测
I2C_BUS=${I2C_BUS:-}              # 留空 -> 从 i2c-HWSP0001:00 自动探测
SPK_VOL_NUMID=${SPK_VOL_NUMID:-}  # 留空 -> 自动探测扬声器音量控件
SPK_VOL_DEFAULT=${SPK_VOL_DEFAULT:-70}   # 仅供说明；音量不会被强制设置（仅在拔耳机时清零）
# ------------------------------------------------

# ---- 参数自动探测辅助函数 ----

detect_i2c() {
    local link
    link=$(readlink -f /sys/bus/i2c/devices/i2c-HWSP0001:00 2>/dev/null)
    [ -n "$link" ] && printf '%s' "$link" | grep -oE 'i2c-[0-9]+' | head -1 | cut -d- -f2
}

detect_jack() {
    amixer -c 0 controls 2>/dev/null \
        | sed -n 's/.*numid=\([0-9]*\).*name=.Headphone Jack.*/\1/p' | head -1
}

detect_spk_vol() {
    local c
    c=$(amixer -c 0 controls 2>/dev/null \
        | sed -n 's/.*numid=\([0-9]*\).*name=.Speaker Playback Volume.*/\1/p' | head -1)
    [ -n "$c" ] && { echo "$c"; return; }
    c=$(amixer -c 0 controls 2>/dev/null \
        | sed -n 's/.*numid=\([0-9]*\).*name=.DAC Playback Volume.*/\1/p' | head -1)
    [ -n "$c" ] && { echo "$c"; return; }
    amixer -c 0 controls 2>/dev/null \
        | sed -n 's/.*numid=\([0-9]*\).*name=.Master Playback Volume.*/\1/p' | head -1
}

# 从 DSDT 解析 HWSP 功放使能 GPIO 线号。
# HWSP _INI 的做法为：PIN1 = GNUM(0x09xx00xx)。GNUM(arg) = GINF(group,6) + (arg & 0xFFFF)
# 其中 GINF(group,6) 即 GPCL[group][6]。结果为 \_SB.GPI0 控制器相对的线号，
# 也就是要传给 gpioset 的值。
detect_gpio() {
    local dsdt=/sys/firmware/acpi/tables/DSDT
    [ -r "$dsdt" ] || return 1
    command -v iasl >/dev/null 2>&1 || return 1
    local tmp
    tmp=$(mktemp -d) || return 1
    iasl -d -p "$tmp/dsdt" "$dsdt" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    python3 - "$tmp/dsdt.dsl" <<'PY' 2>/dev/null
import re
t=open(sys.argv[1]).read()
i=t.find('Device (HWSP')
seg=t[i:i+8192] if i>=0 else ''
m=re.search(r'GNUM\s*\(\s*(0x[0-9A-Fa-f]+)\s*\)', seg)
if not m:
    sys.exit(1)
arg=int(m.group(1),16)
grp=(arg>>16)&0xff
off=arg&0xffff
def parse_table(t,name):
    key='Name ('+name+','
    i=t.find(key)
    if i<0: return None
    j=t.find('{',i)
    d=0;k=j
    while k<len(t):
        if t[k]=='{':d+=1
        elif t[k]=='}':
            d-=1
            if d==0:break
        k+=1
    block=t[j:k+1]
    rows=[];p=0
    while True:
        mm=block.find('Package (',p)
        if mm<0:break
        ob=block.find('{',mm)
        d=0;q=ob
        while q<len(block):
            if block[q]=='{':d+=1
            elif block[q]=='}':
                d-=1
                if d==0:break
            q+=1
        nums=re.findall(r'0x[0-9A-Fa-f]+', block[ob+1:q])
        rows.append([int(x,16) for x in nums])
        p=ob+1
    return rows
tbl=parse_table(t,'GPCL')
if tbl and len(tbl)>grp and len(tbl[grp])>6:
    print(tbl[grp][6]+off)
PY
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

# ---- 解析参数 ----
CMD="${1:-}"
I2C_BUS=$(detect_i2c); [ -n "$I2C_BUS" ] || { echo "错误：找不到 HWSP0001 的 I2C 总线" >&2; exit 1; }
JACK_NUMID=$(detect_jack)
SPK_VOL_NUMID=$(detect_spk_vol)
GPIO_LINE=$(detect_gpio)
GPIO_LINE=${GPIO_LINE:-145}

# 子命令模式（手动控制/排障）：不需要耳机插拔监听，也不依赖 ALSA Jack 控件。
case "$CMD" in
  mute)
    echo "手动软静音扬声器（耳机不受影响）"
    set_amp 0
    exit 0
    ;;
  unmute)
    echo "手动恢复扬声器"
    set_amp 1
    exit 0
    ;;
  status)
    for A in 0x58 0x5B; do
      v=$(i2cget -y -f "$I2C_BUS" "$A" 0x01 2>/dev/null)
      echo "功放 $A 寄存器 0x01 = ${v:-<读取失败>}"
    done
    exit 0
    ;;
esac

# 监听模式才必须能探测到 Jack 控件
[ -n "$JACK_NUMID" ] || { echo "错误：找不到 'Headphone Jack' 控件" >&2; exit 1; }

# ---- PipeWire 音量控制（必须以桌面用户身份运行，而非 root） ----
# 在本机上，单一的 PipeWire sink 同时驱动耳机和扬声器，并且 PipeWire 拥有 ALSA
# 音量控制权。因此拔耳机时的静音必须通过 `wpctl`（以用户身份运行）完成，
# 否则 PipeWire 会立即把旧音量恢复回来。
PW_USER=; PW_RUNTIME=
if command -v wpctl >/dev/null 2>&1; then
    for _d in /run/user/*; do
        [ -S "$_d/pipewire-0" ] && { PW_RUNTIME="$_d"; PW_USER=$(stat -c '%U' "$_d/pipewire-0"); break; }
    done
fi

echo "使用参数：I2C_BUS=$I2C_BUS  JACK_NUMID=$JACK_NUMID  GPIO $GPIOCHIP 线号 $GPIO_LINE  SPK_VOL_NUMID=${SPK_VOL_NUMID:-none}  PipeWire 用户=${PW_USER:-none}"

CURRENT_PID=

# 通过 I2C 回放 HWSP0001 的“使能”寄存器值，让功放恢复工作。
# 这些是功放的使能值（BOD-WXX9 与 BoF-XX 使用相同芯片）。
# 注意：在 BoF-XX 上，BIOS 在开机时把功放留在默认的“静音”状态
# （刚开机的 `i2cdump` 显示的是静音默认值，而不是这里的使能值），
# 因此写入这些使能值正是让声音能正常工作的关键。
reinit_amp() {
    sleep 0.3
    for ADDR in 0x58 0x5B; do
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x01 0x69
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x03 0x16
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x04 0x80
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x05 0x0c
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x06 0x11
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x07 0x93
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x09 0x0b
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x0b 0x4b
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x0c 0x00
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x0d 0x77
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x0f 0x51
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x10 0x58
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x58 0x00
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x59 0x80
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x61 0x16
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x62 0xb5
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x63 0x5a
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x64 0xd5
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x65 0x57
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x66 0x69
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x67 0x28
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x68 0x35
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x69 0x98
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x71 0x9c
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x72 0x33
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x73 0x40
        i2cset -y -f "$I2C_BUS" "$ADDR" 0x74 0x0c
    done
}

set_speaker_vol() {
    [ -n "$SPK_VOL_NUMID" ] || return 0
    amixer -c 0 cset numid="$SPK_VOL_NUMID" "${1}%" >/dev/null 2>&1
}

# PipeWire 音量控制，以桌面用户身份执行（root 无法直接访问用户的 PipeWire 会话）。
# 若 PipeWire 未运行则静默跳过。
set_pw_vol() {
    [ -n "$PW_USER" ] || return 0
    runuser -u "$PW_USER" -- env XDG_RUNTIME_DIR="$PW_RUNTIME" \
        wpctl set-volume @DEFAULT_SINK@ "$1" >/dev/null 2>&1
}

# 在“真正拔掉耳机”的那一刻，先把扬声器音量在 PipeWire 层设为 0（即静音）。
# 重复几次以应对 WirePlumber 在 jack 事件后可能触发的“按端口恢复音量”竞态。
# 注意：这里只在拔耳机跳变瞬间执行一次，之后用户可手动调大音量（不会被反复压制）。
unplug_volume_guard() {
    local i
    for i in 1 2 3; do
        set_pw_vol 0
        set_speaker_vol 0
        sleep 0.25
    done
}

set_amp() {
    local val=$1
    if [ "$val" = "1" ]; then
        # 启用扬声器：确保 HWSP0001 功放供电 GPIO 常开（libgpiod v2：用 -c
        # 选择芯片；末尾的 & 让 gpioset 持续运行，在被杀掉前一直驱动该线），
        # 再回放使能寄存器取消软静音。
        if [ -z "$CURRENT_PID" ] || ! kill -0 "$CURRENT_PID" 2>/dev/null; then
            gpioset -c "$GPIOCHIP" "$GPIO_LINE=1" &
            CURRENT_PID=$!
            sleep 0.2
            if ! kill -0 "$CURRENT_PID" 2>/dev/null; then
                local i
                for i in 1 2 3 4; do
                    sleep 0.2
                    gpioset -c "$GPIOCHIP" "$GPIO_LINE=1" &
                    CURRENT_PID=$!
                    sleep 0.2
                    kill -0 "$CURRENT_PID" 2>/dev/null && break
                done
            fi
        fi
        reinit_amp
    else
        # 禁用扬声器：用 HWSP0001 软静音寄存器（0x01=0x00）。该方式只静音
        # 扬声器，耳机走 ES8336 独立路径不受影响（已实测：写 0x01=0x00 后
        # 扬声器无声、耳机照常响）。保持功放供电 GPIO 常开，不再翻转它。
        i2cset -y -f "$I2C_BUS" 0x58 0x01 0x00 2>/dev/null
        i2cset -y -f "$I2C_BUS" 0x5B 0x01 0x00 2>/dev/null
        echo "已软静音扬声器（耳机不受影响）"
    fi
}

read_jack() {
    amixer -c 0 cget "numid=$JACK_NUMID" 2>/dev/null \
        | sed -n 's/^[[:space:]]*: values=//p'
}

# 根据耳机插孔状态应用功放状态。功放使能 GPIO 仅在“期望的功放状态真正发生变化时”
# 才切换（而非每个事件都切换），从而避免 alsactl 的偶发事件反复拉起/杀死 gpioset。
# 扬声器音量只在“真正拔掉耳机”的跳变时强制设为 0（静音）。
PREV=
CUR_AMP=
apply() {
    local jack
    jack=$(read_jack)
    local transition=0
    [ "$jack" != "$PREV" ] && transition=1

    # 耳机插入 -> 功放关闭；否则功放开启
    local want=1
    [ "$jack" = "on" ] && want=0
    if [ "$want" != "$CUR_AMP" ]; then
        set_amp "$want"
        CUR_AMP=$want
    fi

    # 真正拔掉耳机：先把扬声器音量设为 0（静音，通过拥有音量的 PipeWire 完成），
    # 这样重新上电的功放绝不会以之前耳机的音量突然炸响。之后用户可手动调大音量。
    if [ "$transition" = "1" ] && [ "$PREV" = "on" ] && [ "$jack" = "off" ]; then
        unplug_volume_guard
    fi
    PREV=$jack
}

cleanup() {
    [ -n "$CURRENT_PID" ] && kill "$CURRENT_PID" 2>/dev/null
    exit 0
}

# 杀掉上一次运行残留、仍占用本使能线的 gpioset；
# 否则新的 gpioset 会因 EBUSY 失败，导致没有任何进程驱动功放。
pkill -9 -f "gpioset -c $GPIOCHIP $GPIO_LINE" 2>/dev/null

trap cleanup TERM INT
apply
alsactl monitor hw:0 2>/dev/null | while read -r _; do
    apply
done
