#!/bin/bash
# 华为 MateBook 扬声器功放（HWSP0001）插拔耳机自动静音/切换修复脚本
#
# HWSP0001 功放没有 Linux 驱动。部分机型（如 BOD-WXX9）BIOS 会在开机时通过
# SMM 初始化一次功放；但另一些机型（如 BoF-XX）会把功放留在默认的"静音"状态。
# Linux 既无法在插入耳机时把功放静音，也无法在 GPIO 断电后重新初始化它。
# 本脚本监听 ALSA 的"Headphone Jack"控件，切换功放使能 GPIO，并在功放重新
# 上电时通过 I2C 回放功放的"使能"寄存器值。
#
# 关键参数均在运行时自动探测：
#   * I2C 总线       ：来自 /sys/bus/i2c/devices/i2c-HWSP0001:00
#   * Jack 控件 numid：来自 ALSA 的 "Headphone Jack" 控件
#   * GPIO 线号      ：由 DSDT 中 HWSP 的 _INI 的 GNUM() 参数解析得到
#                      （通过 iasl 反汇编），失败时回退到下面的 GPIO_LINE
#   * 扬声器音量控件 ：来自 "DAC / Speaker / Master Playback Volume"
#
# 安全特性：当"拔掉耳机"时（jack on -> off），扬声器音量会被强制设为 0
# （通过 PipeWire，因为它在本机上拥有音量控制权），这样重新上电的功放就不会
# 以之前耳机的音量突然炸响。用户随后可手动调大音量。插入耳机 / 开机时音量
# 保持不变。

# ---------- 可配置项（可用环境变量覆盖） ----------
GPIOCHIP=${GPIOCHIP:-gpiochip0}
GPIO_LINE=${GPIO_LINE:-}          # 留空 -> 通过 DSDT(iasl) 自动探测，否则用 145
JACK_NUMID=${JACK_NUMID:-}        # 留空 -> 从 "Headphone Jack" 自动探测
I2C_BUS=${I2C_BUS:-}              # 留空 -> 从 i2c-HWSP0001:00 自动探测
SPK_VOL_NUMID=${SPK_VOL_NUMID:-}  # 留空 -> 自动探测扬声器音量控件
SPK_VOL_DEFAULT=${SPK_VOL_DEFAULT:-70}   # 仅供说明；音量不会被强制设置（仅在拔耳机时清零）
HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-60}  # 健康检查间隔（秒），默认60秒
POLL_INTERVAL=${POLL_INTERVAL:-5}  # 轮询兜底间隔（秒），默认5秒；同时也是 input event 监听的再校准周期
# ------------------------------------------------

# ---------- DMI 机型识别：决定是否需要用户态操控 GPIO ----------
# 两种机型行为差异（关键发现！）：
#   - BOD-WXX9 / 类似老机型：BIOS 开机时不初始化 HWSP0001 功放的 GPIO 供电脚，
#     必须由用户态通过 gpioset 持续拉对应线为高，功放 I2C 才可访问。
#   - BoF-XX (MateBook D 15 BoF-XX-PCB) 等新机型：BIOS 启动时已经正确设置
#     功放 GPIO 使能脚并完成供电，用户态若再次用 gpioset 拉该线反而会破坏
#     BIOS 建立的引脚状态，导致功放 I2C 永久无法访问（必须重启机器再次 BIOS
#     初始化才能恢复）。
# 因此：用 DMI "product_name"（/sys/class/dmi/id/product_name）判断。
detect_dmi_gpio_needed() {
    local product="" product_fallback=""
    [ -r /sys/class/dmi/id/product_name ] && product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    [ -r /sys/class/dmi/id/board_name ] && product_fallback=$(cat /sys/class/dmi/id/board_name 2>/dev/null)
    case "${product:-$product_fallback}" in
        BoF*)
            # BoF-XX / BoF-XX-PCB 等：BIOS 已处理 GPIO，用户态不要碰
            echo "0:$product:$product_fallback"
            return 0
            ;;
        BOD*|BOH*)
            # BOD-WXX9 / BOHB-WAX9-PCB-B2 等：需要用户态 gpioset
            echo "1:$product:$product_fallback"
            return 0
            ;;
    esac
    # 未知机型：默认需要 GPIO（保守，不破坏更重要的 BOD 系列）
    # 可通过 NEEDS_GPIO 环境变量覆盖
    echo "1:$product:$product_fallback"
    return 0
}

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
import sys
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

# ---- 探测 PipeWire 用户（运行时重试，应对开机时用户会话未就绪） ----
detect_pw() {
    PW_USER=; PW_RUNTIME=
    if command -v wpctl >/dev/null 2>&1; then
        local _d
        for _d in /run/user/*; do
            [ -S "$_d/pipewire-0" ] && { PW_RUNTIME="$_d"; PW_USER=$(stat -c '%U' "$_d/pipewire-0"); break; }
        done
    fi
}

# ---- 探测用于耳机插拔监听的 input event 设备 ----
# sof_es8336 驱动会创建形如 "sof-essx8336 Headset" 的 input 设备，
# 通过 SW_HEADPHONE_INSERT / SW_MICROPHONE_INSERT 上报插拔事件。
# 此通道比 alsactl monitor 更可靠（在 BoF-XX 等机型上 alsactl monitor 不会产生任何事件）。
detect_input_jack_dev() {
    local ev name d rp
    for d in /sys/class/input/event*; do
        [ -e "$d/device/name" ] || continue
        name=$(cat "$d/device/name" 2>/dev/null)
        case "$name" in
            *Headset*)
                ev=$(basename "$d")
                rp=$(readlink -f "$d/device" 2>/dev/null)
                case "$rp" in
                    */sound/card0*) echo "/dev/input/$ev"; return 0 ;;
                esac
                # 若路径中没有 sound/card0 显式信息，但名称匹配也返回
                echo "/dev/input/$ev"; return 0
                ;;
        esac
    done
    return 1
}

# ---- 统一的耳机插拔事件监视器（Python 实现） ----
# 优先级：1) /dev/input/eventN 的 SW 事件（主通道）
#        2) 每 POLL_INTERVAL 秒的 amixer 轮询（兜底，防止任何事件丢失）
# 输出格式：每行 "JACK_STATE <on|off>"，供 bash 侧消费
# 参数：$1=input设备路径  $2=JACK_NUMID  $3=轮询间隔(秒)
jack_monitor() {
    local input_dev="$1" numid="$2" poll_interval="$3"
    python3 - "$input_dev" "$numid" "$poll_interval" <<'PYEOF'
import sys, os, struct, time, select, subprocess, re

input_dev, numid, poll_interval = sys.argv[1], sys.argv[2], int(sys.argv[3])
fmt = "=qqHHi"
fmt_size = struct.calcsize(fmt)
EV_SW = 0x05
SW_HP_INSERT = 0x02

def read_jack():
    try:
        out = subprocess.check_output(
            ["amixer", "-c", "0", "cget", "numid=%s" % numid],
            stderr=subprocess.DEVNULL, timeout=3
        ).decode(errors="replace")
        m = re.search(r": values=(\w+)", out)
        return m.group(1) if m else None
    except Exception:
        return None

def emit(state):
    sys.stdout.write("JACK_STATE %s\n" % state)
    sys.stdout.flush()

# 启动时先输出一次当前状态（保证启动时插着耳机的场景能立刻被上层捕获）
last_state = None
for _attempt in range(10):
    cur = read_jack()
    if cur in ("on", "off"):
        emit(cur)
        last_state = cur
        break
    time.sleep(0.3)

# 打开 input 事件设备
f = None
try:
    if os.access(input_dev, os.R_OK):
        f = open(input_dev, "rb")
except Exception:
    f = None

if f is None:
    # 降级为纯 amixer 轮询
    while True:
        time.sleep(poll_interval)
        s = read_jack()
        if s in ("on", "off") and s != last_state:
            emit(s)
            last_state = s
    sys.exit(0)

last_poll = time.time()
while True:
    timeout = max(0.1, poll_interval - (time.time() - last_poll))
    try:
        r, _, _ = select.select([f], [], [], timeout)
    except InterruptedError:
        r = []
    now = time.time()
    event_triggered = False
    if r:
        try:
            d = f.read(fmt_size)
            if len(d) < fmt_size:
                # 设备断开：尝试重新打开
                f.close()
                time.sleep(1)
                try:
                    f = open(input_dev, "rb")
                    continue
                except Exception:
                    break
            sec, usec, t, c, v = struct.unpack(fmt, d)
            if t == EV_SW and c == SW_HP_INSERT:
                event_triggered = True
        except Exception:
            pass
    # 无论是收到 HP 插入事件还是到了轮询周期，都读一次 ALSA 状态
    if event_triggered or (now - last_poll >= poll_interval):
        s = read_jack()
        if s in ("on", "off") and s != last_state:
            emit(s)
            last_state = s
        last_poll = now
PYEOF
}

# 判断功放供电 gpioset 是否正在运行（pgrep 作为唯一真相源，
# 避免主 shell 与 health_check 子 shell 之间 CURRENT_PID 不同步造成的竞态）
# BoF-XX 机型 BIOS 已处理 GPIO：此函数恒返回 true（GPIO 永远处于"已就绪"状态）。
gpioset_running() {
    if [ "${NEEDS_GPIO:-1}" = "0" ]; then
        return 0
    fi
    pgrep -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" >/dev/null 2>&1
}

# 通过 I2C 回放 HWSP0001 的"使能"寄存器值，让功放恢复工作。
# 参数 $1: 1 = 使能扬声器 (reg0x01=0x69)，0 = 软静音 (reg0x01=0x00)
# 返回: 0=所有寄存器写后读回成功；非0=存在失败
reinit_amp() {
    local mode=${1:-1}
    # 若 gpioset 是刚拉起的或当前不稳定，功放供电还在爬升，需更多时间。
    # 这里额外 sleep 确保 I2C 总线可以访问。
    local ADDR reg val ok=0
    for ADDR in 0x58 0x5B; do
        # 第一步：reg0x01 决定静音 / 使能
        if [ "$mode" = "1" ]; then
            i2cset -y -f "$I2C_BUS" "$ADDR" 0x01 0x69 2>/tmp/i2c_err_$$.log || true
        else
            i2cset -y -f "$I2C_BUS" "$ADDR" 0x01 0x00 2>/tmp/i2c_err_$$.log || true
        fi
        [ "$mode" != "1" ] && continue   # 静音模式：只需要写 reg0x01
        # 其余寄存器按 amp_0x5X_init.txt 中记录的"出声状态"值回放
        while read -r reg val; do
            # (reg / val 已在循环中逐行赋值，属局部循环变量语义)
            case "$reg" in
                0x01|0x03|0x04|0x05|0x06|0x07|0x09|0x0b|0x0c|0x0d|0x0f|\
                0x10|0x58|0x59|0x61|0x62|0x63|0x64|0x65|0x66|0x67|0x68|\
                0x69|0x71|0x72|0x73|0x74)
                    i2cset -y -f "$I2C_BUS" "$ADDR" "$reg" "$val" 2>/tmp/i2c_err_$$.log || true
                    ;;
            esac
        done <<'REGINIT'
0x03 0x16
0x04 0x80
0x05 0x0c
0x06 0x11
0x07 0x93
0x09 0x0b
0x0b 0x4b
0x0c 0x00
0x0d 0x77
0x0f 0x51
0x10 0x58
0x58 0x00
0x59 0x80
0x61 0x16
0x62 0xb5
0x63 0x5a
0x64 0xd5
0x65 0x57
0x66 0x69
0x67 0x28
0x68 0x35
0x69 0x98
0x71 0x9c
0x72 0x33
0x73 0x40
0x74 0x0c
REGINIT
    done
    # 读回 reg0x01 验证
    local expected v58 v5b
    expected="0x69"; [ "$mode" = "0" ] && expected="0x00"
    v58=$(i2cget -y -f "$I2C_BUS" 0x58 0x01 2>/dev/null)
    v5b=$(i2cget -y -f "$I2C_BUS" 0x5B 0x01 2>/dev/null)
    [ "$v58" = "$expected" ] && [ "$v5b" = "$expected" ] && ok=1
    rm -f /tmp/i2c_err_$$.log
    if [ "$ok" = "1" ]; then
        return 0
    else
        echo "[$(date '+%F %T')] reinit_amp 验证失败 (期望 $expected, 实际 0x58=${v58:-<fail>} 0x5B=${v5b:-<fail>})" >&2
        return 1
    fi
}

set_speaker_vol() {
    [ -n "$SPK_VOL_NUMID" ] || return 0
    amixer -c 0 cset numid="$SPK_VOL_NUMID" "${1}%" >/dev/null 2>&1
}

# PipeWire 音量控制，以桌面用户身份执行（root 无法直接访问用户的 PipeWire 会话）。
# 若 PipeWire 未运行则静默跳过。
# 把"多次 set-volume 0 以应对 WirePlumber 音量恢复竞态"放进同一个 runuser 会话内完成，
# 避免每次 unplug 触发多次 PAM 会话（日志中可见 session opened/closed 刷屏）。
set_pw_vol() {
    [ -n "$PW_USER" ] || return 0
    runuser -u "$PW_USER" -- env XDG_RUNTIME_DIR="$PW_RUNTIME" PW_VOL_TARGET="$1" bash -c '
        for i in 1 2 3; do
            wpctl set-volume @DEFAULT_SINK@ "$PW_VOL_TARGET" >/dev/null 2>&1
            sleep 0.25
        done
    '
}

# 在"真正拔掉耳机"的那一刻，先把扬声器音量在 PipeWire 层设为 0（即静音）。
# 重复几次以应对 WirePlumber 在 jack 事件后可能触发的"按端口恢复音量"竞态。
# 注意：这里只在拔耳机跳变瞬间执行一次，之后用户可手动调大音量（不会被反复压制）。
unplug_volume_guard() {
    # PipeWire 层清零（单次 runuser 会话内完成 3 次 set-volume，避免 PAM 抖动）
    set_pw_vol 0
    # ALSA 层同样清零（root 直接调 amixer，无 PAM 开销），兜底确保不出声。
    local i
    for i in 1 2 3; do
        set_speaker_vol 0
        sleep 0.25
    done
}

# 启动 gpioset 保持功放供电 GPIO 为高（仅限 NEEDS_GPIO=1 的机型）。
# BoF-XX (NEEDS_GPIO=0)：此函数为 NO-OP（BIOS 已拉好 GPIO，用户态不要重写电平）。
start_gpioset() {
    if [ "${NEEDS_GPIO:-1}" = "0" ]; then
        return 0
    fi
    pkill -9 -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" 2>/dev/null
    sleep 0.3
    local i
    for i in 1 2 3; do
        gpioset -c "$GPIOCHIP" "$GPIO_LINE=1" &
        local gpid=$!
        disown $gpid 2>/dev/null
        sleep 0.5
        if gpioset_running; then
            return 0
        fi
        sleep 0.3
    done
    echo "[$(date '+%F %T')] start_gpioset 失败：3 次尝试后仍无法拉起 gpioset $GPIOCHIP $GPIO_LINE=1" >&2
    return 1
}

set_amp() {
    local val=$1
    local need_gpio_start=0

    # 无论静音 / 非静音，I2C 写入都需要功放供电 GPIO 为高。
    # BoF-XX (NEEDS_GPIO=0)：gpio_running 恒 true，跳过整个启动分支。
    if ! gpioset_running; then
        echo "[$(date '+%F %T')] set_amp($val): gpioset 未运行，先启动功放供电..."
        if start_gpioset; then
            need_gpio_start=1
        else
            echo "[$(date '+%F %T')] set_amp($val): 无法启动功放供电 GPIO，后续 I2C 写入将失败" >&2
        fi
    fi

    if [ "$val" = "1" ]; then
        # 启用扬声器：确保 GPIO 供电稳定 → 回放全部寄存器 → 验证读回。
        # 如果是刚拉起的 GPIO（仅 NEEDS_GPIO=1），功放供电需要更多建立时间（>1s）。
        echo "[$(date '+%F %T')] set_amp(1): 恢复扬声器 (I2C 写入使能寄存器)..."
        if [ "${NEEDS_GPIO:-1}" = "1" ] && [ "$need_gpio_start" = "1" ]; then
            sleep 1.2
        else
            sleep 0.15  # BoF 机型 BIOS 已供好电，短延迟即可（无需等 LDO 稳定）
        fi
        local attempt delays
        delays=(0.6 1.2 2.0)
        for attempt in 1 2 3; do
            if reinit_amp 1; then
                echo "[$(date '+%F %T')] set_amp(1): 扬声器已恢复 (尝试 $attempt/3 成功)"
                return 0
            fi
            echo "[$(date '+%F %T')] set_amp(1): 第 $attempt 次失败，重置 GPIO 供电后重试 (${delays[$((attempt-1))]}s)..." >&2
            # BoF 机型：不要切 GPIO！直接重试 I2C 写入即可（GPIO 是 BIOS 的）
            if [ "${NEEDS_GPIO:-1}" = "1" ]; then
                pkill -9 -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" 2>/dev/null
                sleep "${delays[$((attempt-1))]}"
                start_gpioset || { echo "  → GPIO 重启失败，放弃" >&2; break; }
                sleep 1.0
            else
                sleep "${delays[$((attempt-1))]}"
            fi
        done
        echo "[$(date '+%F %T')] set_amp(1): 全部 3 次重试失败，扬声器可能仍无声" >&2
        return 1
    else
        # 软静音扬声器：只写 reg0x01=0x00，保持 GPIO 供电常开。
        # 调用 reinit_amp 0 进行写入 + 读回验证。
        sleep 0.1
        local j
        for j in 1 2; do
            if reinit_amp 0 2>/dev/null; then
                echo "已软静音扬声器（耳机不受影响）"
                return 0
            fi
            sleep 0.5
        done
        # 回读验证失败时，仍保证做了一次写入尝试
        i2cset -y -f "$I2C_BUS" 0x58 0x01 0x00 2>/dev/null
        i2cset -y -f "$I2C_BUS" 0x5B 0x01 0x00 2>/dev/null
        echo "已软静音扬声器（耳机不受影响） [I2C 验证失败，已尽力写入]"
        return 0
    fi
}

read_jack() {
    amixer -c 0 cget "numid=$JACK_NUMID" 2>/dev/null \
        | sed -n 's/^[[:space:]]*: values=//p'
}

# ---- jack 检测通道设备级存活检查（捕获设备消失/不可读这类硬失效） ----
# 注意：此函数只能判定"设备节点是否可读"，无法发现"设备可读但内核静默冻结"
# （静默冻结需真实插拔才暴露，见 status 子命令提示）。
# 返回 0=事件设备可读；非0=设备不可读。
check_jack_detection() {
    local dev
    dev=$(detect_input_jack_dev)
    [ -n "$dev" ] && [ -r "$dev" ] && return 0
    return 1
}

# ---- 桌面/系统级告警：jack 检测死亡时通知用户（多层级兜底） ----
# 层级：①桌面通知(notify-send，以桌面用户身份发) → ②wall 广播给所有 TTY
#       → ③logger 写系统日志（持久可查）。
# 自动探测桌面用户（优先复用已探测的 PW_USER，否则扫描 /run/user 下持有
# DISPLAY 或 wayland socket 的用户），确保弹窗落到正确的图形会话。
JACK_ALERT_RAISED=0   # 去重：已弹过告警则不再刷屏，直到恢复后重置
notify_jack_dead() {
    local msg="耳机插拔检测(jack)已失效：耳机插拔联动静音将不起作用，需整机重启恢复音频。"
    local ts; ts=$(date '+%F %T')

    # ① 桌面通知（critical 级，置顶+提示音）
    local u pw_dir disp addr sent=1
    for u in "${PW_USER:-}" ""; do
        [ -n "$u" ] || {
            # 自动探测：持有 DISPLAY 或 wayland socket 的用户
            for pw_dir in /run/user/*; do
                [ -S "$pw_dir/dbus-1" ] || [ -S "$pw_dir/bus" ] || continue
                u=$(stat -c '%U' "$pw_dir/dbus-1" 2>/dev/null \
                    || stat -c '%U' "$pw_dir/bus" 2>/dev/null)
                [ -n "$u" ] && break
            done
        }
        [ -n "$u" ] || break
        pw_dir="/run/user/$(id -u "$u" 2>/dev/null)"
        [ -d "$pw_dir" ] || continue
        addr="unix:path=$pw_dir/bus"
        [ -S "$pw_dir/bus" ] || addr="unix:path=$pw_dir/dbus-1"
        disp=":0"
        [ -n "$DISPLAY" ] && disp="$DISPLAY"
        if command -v runuser >/dev/null 2>&1 && command -v notify-send >/dev/null 2>&1; then
            runuser -u "$u" -- env DISPLAY="$disp" XDG_RUNTIME_DIR="$pw_dir" \
                DBUS_SESSION_BUS_ADDRESS="$addr" \
                notify-send -u critical -a huawei-speaker-mute \
                "耳机检测失效" "$msg" 2>/dev/null && sent=0
        fi
        [ "$sent" = "0" ] && break
    done

    # ② wall 广播给所有登录 TTY（不依赖桌面）
    if command -v wall >/dev/null 2>&1; then
        echo "[$ts] $msg (需整机重启恢复)" | wall 2>/dev/null || true
    fi

    # ③ 写系统日志（持久可查）
    if command -v logger >/dev/null 2>&1; then
        logger -t huawei-speaker-mute -p user.crit "jack 检测失效：$msg"
    fi
    echo "[$ts] 已发出 jack 检测失效告警（桌面通知/广播/日志）" >&2
}

# ---- 解析参数 ----
CMD="${1:-}"
I2C_BUS=$(detect_i2c); [ -n "$I2C_BUS" ] || { echo "错误：找不到 HWSP0001 的 I2C 总线" >&2; exit 1; }

# 子命令模式（手动控制/排障）：不需要耳机插拔监听，也不依赖 ALSA Jack 控件。
# 需要先完成 GPIO 和 PipeWire 探测。
GPIO_LINE=$(detect_gpio)
GPIO_LINE=${GPIO_LINE:-145}

# ---- 初始化 NEEDS_GPIO 标志（DMI 探测，允许环境变量覆盖） ----
# 输出格式："<NEEDS_GPIO>:<product_name>:<board_name>"
_DMI_INFO=""
_DMI_INFO=$(detect_dmi_gpio_needed)
case ":$_DMI_INFO:" in
    ::)
        NEEDS_GPIO="${NEEDS_GPIO:-1}"
        DMI_PRODUCT=""; DMI_BOARD=""
        ;;
    *)
        if [ -z "${NEEDS_GPIO:-}" ]; then
            NEEDS_GPIO="${_DMI_INFO%%:*}"
        fi
        _rest="${_DMI_INFO#*:}"
        DMI_PRODUCT="${_rest%%:*}"
        DMI_BOARD="${_rest#*:}"
        ;;
esac
export NEEDS_GPIO
detect_pw

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
    A=""
    v=""
    for A in 0x58 0x5B; do
      v=$(i2cget -y -f "$I2C_BUS" "$A" 0x01 2>/dev/null)
      echo "功放 $A 寄存器 0x01 = ${v:-<读取失败>}"
    done
    if pgrep -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" >/dev/null 2>&1; then
        echo "GPIO 供电进程存活"
    else
        echo "GPIO 供电进程未启动"
    fi
    # jack 检测通道存活（设备级）；注意静默冻结需真实插拔才暴露
    if check_jack_detection >/dev/null 2>&1; then
        echo "jack 检测通道：设备可读（若插拔无反应，可能内核静默冻结，需重启恢复）"
    else
        echo "jack 检测通道：异常（设备不可读），耳机插拔联动可能已失效"
    fi
    exit 0
    ;;
esac

# 监听模式：等待 ALSA Jack 控件就绪（开机时声卡可能未立即就绪）
JACK_NUMID=$(detect_jack)
if [ -z "$JACK_NUMID" ]; then
    echo "等待 ALSA 'Headphone Jack' 控件就绪..."
    retry=""
    for retry in $(seq 1 15); do
        sleep 2
        JACK_NUMID=$(detect_jack)
        [ -n "$JACK_NUMID" ] && break
    done
fi
[ -n "$JACK_NUMID" ] || { echo "错误：找不到 'Headphone Jack' 控件" >&2; exit 1; }

SPK_VOL_NUMID=$(detect_spk_vol)

# 探测用于监听耳机插拔的 input 事件设备
# （开机早期 input 设备可能未就绪，重试几次）
JACK_INPUT_DEV=$(detect_input_jack_dev)
if [ -z "$JACK_INPUT_DEV" ]; then
    retry=""
    for retry in $(seq 1 5); do
        sleep 1
        JACK_INPUT_DEV=$(detect_input_jack_dev)
        [ -n "$JACK_INPUT_DEV" ] && break
    done
fi

_GPIO_NOTE=""
if [ "${NEEDS_GPIO:-1}" = "0" ]; then
    _GPIO_NOTE="(DMI=[${DMI_PRODUCT:-unknown}/${DMI_BOARD:-unknown}] → BIOS 已接管功放 GPIO，用户态不操作)"
else
    _GPIO_NOTE="(DMI=[${DMI_PRODUCT:-unknown}/${DMI_BOARD:-unknown}] → 用户态拉功放 GPIO 供电)"
fi
echo "使用参数：I2C_BUS=$I2C_BUS  JACK_NUMID=$JACK_NUMID  GPIO $GPIOCHIP 线号 $GPIO_LINE" \
     " NEEDS_GPIO=${NEEDS_GPIO:-1} $_GPIO_NOTE" \
     " SPK_VOL_NUMID=${SPK_VOL_NUMID:-none}  PipeWire 用户=${PW_USER:-none}" \
     " 健康检查间隔=${HEALTH_CHECK_INTERVAL}s  轮询间隔=${POLL_INTERVAL}s"
[ -n "$JACK_INPUT_DEV" ] \
    && echo "耳机插拔监听通道：input event ($JACK_INPUT_DEV) + 轮询（主）；alsactl monitor（次）" \
    || echo "耳机插拔监听通道：未检测到 input event 设备，使用 alsactl monitor + 轮询"

# 根据耳机插孔状态应用功放状态。功放使能 GPIO 仅在"期望的功放状态真正发生变化时"
# 才切换（而非每个事件都切换），从而避免 alsactl 的偶发事件反复拉起/杀死 gpioset。
# 扬声器音量只在"真正拔掉耳机"的跳变时强制设为 0（静音）。
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

# 健康检查：防止 gpioset 意外退出或功放寄存器被意外重置
# 每 HEALTH_CHECK_INTERVAL 秒检查一次，发现异常自动恢复。
# 注意：此函数在子 shell 中运行，不能依赖主进程的 CUR_AMP 变量，
# 必须直接从 ALSA 读取当前 jack 状态来判断期望的功放状态。
health_check() {
    # 直接从 ALSA 读取当前 jack 状态
    local jack want expected
    jack=$(read_jack)
    want=1
    [ "$jack" = "on" ] && want=0
    [ "$want" = "1" ] && expected="0x69" || expected="0x00"

    # 仅 NEEDS_GPIO=1 机型需要检查 & 重启 gpioset。
    # BoF-XX 机型：BIOS 控制 GPIO，内核直接读状态。
    if [ "${NEEDS_GPIO:-1}" = "1" ] && ! gpioset_running; then
        echo "[$(date '+%F %T')] 健康检查：GPIO 供电进程丢失，正在重启..."
        if start_gpioset; then
            sleep 0.8
            reinit_amp "$want" >/dev/null 2>&1 || true
            echo "[$(date '+%F %T')] 健康检查：GPIO 供电已恢复"
        else
            echo "[$(date '+%F %T')] 健康检查：GPIO 供电重启失败" >&2
        fi
    fi

    # 验证功放 0x01 寄存器是否处于合法值
    local v58 v5b attempts
    v58=$(i2cget -y -f "$I2C_BUS" 0x58 0x01 2>/dev/null)
    v5b=$(i2cget -y -f "$I2C_BUS" 0x5B 0x01 2>/dev/null)
    if [ "$v58" != "$expected" ] || [ "$v5b" != "$expected" ]; then
        echo "[$(date '+%F %T')] 健康检查：功放寄存器异常 (期望 $expected, 实际 0x58=${v58:-<fail>} 0x5B=${v5b:-<fail>})，正在恢复..."
        # 使用统一的 reinit_amp（带重试、带读回验证），最多 2 次尝试
        for attempts in 1 2; do
            if reinit_amp "$want" >/dev/null 2>&1; then
                echo "[$(date '+%F %T')] 健康检查：功放寄存器已恢复 (尝试 $attempts/2)"
                return 0
            fi
            # NEEDS_GPIO=1：再重启一次 GPIO；BoF-XX 不碰 GPIO
            if [ "${NEEDS_GPIO:-1}" = "1" ]; then
                pkill -9 -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" 2>/dev/null
                sleep 0.8
                start_gpioset >/dev/null 2>&1 || break
                sleep 1.0
            else
                sleep 0.8
            fi
        done
        echo "[$(date '+%F %T')] 健康检查：功放寄存器恢复失败" >&2
    fi

    # jack 检测通道设备级存活检查（捕获设备消失/不可读这类硬失效）
    # 设备不可读 => 联动彻底失效，弹系统级告警（去重：已告警则不再刷屏）。
    # 设备恢复可读 => 重置去重标志，下次再死可重新告警。
    if check_jack_detection; then
        JACK_ALERT_RAISED=0
    else
        if [ "${JACK_ALERT_RAISED:-0}" != "1" ]; then
            JACK_ALERT_RAISED=1
            notify_jack_dead
        fi
    fi

    # 如果 PipeWire 用户还未探测到，重试（应对开机时用户会话未就绪）
    if [ -z "$PW_USER" ]; then
        detect_pw
        if [ -n "$PW_USER" ]; then
            echo "[$(date '+%F %T')] 健康检查：PipeWire 用户已就绪 ($PW_USER)"
        fi
    fi
}

cleanup() {
    if [ "${NEEDS_GPIO:-1}" = "1" ]; then
        pkill -9 -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" 2>/dev/null
    fi
    exit 0
}

# 杀掉上一次运行残留、仍占用本使能线的 gpioset（仅 NEEDS_GPIO=1）
if [ "${NEEDS_GPIO:-1}" = "1" ]; then
    pkill -9 -f "gpioset -c $GPIOCHIP.*$GPIO_LINE" 2>/dev/null
fi

trap cleanup TERM INT

# 始终先启动功放供电 GPIO（BoF-XX 机型为 NO-OP，不会破坏 BIOS 状态）
start_gpioset

# 首次应用状态
apply

# ---- 启动健康检查后台循环 ----
# 注意：子 shell 中的 health_check 直接从 ALSA 读取 jack 状态，
# 不依赖主进程的 CUR_AMP/CURRENT_PID 变量（子 shell 无法获取父进程的变量更新）。
(
    while true; do
        sleep "$HEALTH_CHECK_INTERVAL"
        health_check
    done
) &

# ---------- 统一的耳机插拔监听（三级兜底，使用进程取代避免子 shell 变量作用域问题） ----------
# 第一级：Python 监听 input event（SW_HEADPHONE_INSERT）+ 周期轮询，输出 "JACK_STATE on/off"
# 第二级：alsactl monitor hw:0 （在某些机型可能从不产生事件，但作为兼容通道）
# 第三级：纯轮询模式（每 2 秒），作为前两级都失效时的最后兜底

# ---- 第一级：优先使用 input event + 轮询 的统一监视器 ----
MONITOR_RUNNING=0
if [ -n "$JACK_INPUT_DEV" ] && command -v python3 >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] 启动主监听通道：input event ($JACK_INPUT_DEV) + 每 ${POLL_INTERVAL}s 轮询"
    MONITOR_RUNNING=1
    # 关键：使用 < <(进程替换) 而非管道 | ，确保 while 循环在主进程内执行，
    # PREV / CUR_AMP 变量能正确持久化，不会因 subshell 而丢失。
    while read -r _marker _state _rest; do
        [ "$_marker" = "JACK_STATE" ] || continue
        apply
    done < <(jack_monitor "$JACK_INPUT_DEV" "$JACK_NUMID" "$POLL_INTERVAL")
    echo "[$(date '+%F %T')] 警告：主监听通道 (input event) 已退出，切换到 alsactl monitor"
    MONITOR_RUNNING=0
fi

# ---- 第二级：alsactl monitor ----
if [ "$MONITOR_RUNNING" = "0" ]; then
    MONITOR_RUNNING=1
    # 同样用进程取代管道，避免变量在 subshell 中丢失
    while read -r _; do
        apply
    done < <(alsactl monitor hw:0 2>/dev/null)
    echo "[$(date '+%F %T')] 警告：alsactl monitor 已退出，切换为纯轮询模式"
    MONITOR_RUNNING=0
fi

# ---- 第三级（最后兜底）：每 2 秒轮询 ALSA 控件 ----
echo "[$(date '+%F %T')] 进入最终兜底：纯轮询模式（每 2 秒）"
while true; do
    sleep 2
    apply
done
