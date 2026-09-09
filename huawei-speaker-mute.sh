#!/bin/bash
# 华为 MateBook HWSP0001 功放最小化控制脚本
#
# 功能（3 项，均围绕耳机插孔事件联动）：
#   1) 插耳机 → 写功放 0x58/0x5B 寄存器 0x01 = 0x00 → 扬声器不出声
#   2) 拔耳机 → 写功放 0x58/0x5B 寄存器 0x01 = 0x69 → 扬声器出声
#   3) 插耳机 → 设 es8316 差分路由 Differential Mux='lin2-rin2'
#      （UCM 默认 lin1-rin1 会静音耳机麦；本机实测信号在 lin2-rin2）
#
# 关于"扬声器+耳机同时出声"：不会发生。插耳机时功放被静音(0x00)，
# 扬声器物理无输出；耳机声音由 codec HP 通道独立驱动，与功放无关。
#
# AMP_SETTLE_DELAY：jack 变化后延迟再写 I2C，避开内核 DAPM 操作
# HP 电源域的竞争窗口，防止 codec jack-detect 锁死。

AMP_SETTLE_DELAY=${AMP_SETTLE_DELAY:-1.5}

# 探测 I2C 总线号（功放挂载在 HWSP0001:00）
# /sys/bus/i2c/devices/i2c-HWSP0001:00 是目录，其下有 name 文件
# 设备节点形如 /sys/bus/i2c/devices/4-0058（总线号-地址）
detect_i2c_bus() {
    local f
    # 方法1：通过 HWSP0001:00 别名找同名目录
    if [ -d /sys/bus/i2c/devices/i2c-HWSP0001:00 ]; then
        for f in /sys/bus/i2c/devices/*-0058; do
            [ -d "$f" ] || continue
            local bus=${f##*/}      # 4-0058
            bus=${bus%%-*}           # 4
            [ -n "$bus" ] && { echo "$bus"; return 0; }
        done
    fi
    # 方法2：直接探测哪些总线能读到 0x58
    local b
    for b in 0 1 2 3 4 5 6 7 8 9 10 11; do
        i2cget -y -f "$b" 0x58 0x01 >/dev/null 2>&1 && { echo "$b"; return 0; }
    done
    echo 0
}
I2C_BUS=${I2C_BUS:-$(detect_i2c_bus)}

# DMI 识别：BoF-XX 由 BIOS 管 GPIO，用户态不要碰
NEEDS_GPIO=1
_product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
_board=$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)
case "${_product:-$_board}" in
    BoF*) NEEDS_GPIO=0 ;;
esac

# 探测 input event 耳机插孔设备
# 判定依据：sysfs capabilities/sw 的 bit2(SW_HEADPHONE_INSERT)=1。
# 找不到时输出空（调用方跳过监听）——绝不硬编码 event* 编号：input 设备
# 编号会随声卡加载/卸载漂移，硬编码会监听到错误设备或已删除设备（
# 已删除设备的 fd 会让 select 立即返回 + read 报 ENODEV，导致 100% CPU 忙循环）。
detect_input_jack_dev() {
    local d real sw
    for d in /dev/input/event*; do
        [ -r "$d" ] || continue
        # eventX 与 inputY 编号可能错位（实测 event10 ↔ input23），
        # 必须通过 symlink 解析真实 input 节点再读能力位。
        real=$(readlink -f "/sys/class/input/$(basename "$d")" 2>/dev/null) || continue
        sw=$(cat "${real%/event*}/capabilities/sw" 2>/dev/null)
        if [ -n "$sw" ] && [ $((0x$sw & 0x04)) -ne 0 ]; then
            echo "$d"; return 0
        fi
    done
    for d in /dev/input/by-path/*Headset*; do [ -r "$d" ] && { readlink -f "$d"; return 0; }; done
    echo ""
}
JACK_INPUT_DEV=$(detect_input_jack_dev)

# 核心：写功放 0x01 使能寄存器（mode 1=出声 0x69 / 0=静音 0x00）
# 两个地址 0x58 0x5B 都写，带读回验证
set_amp() {
    local mode=$1
    local expected="0x69"; [ "$mode" = "0" ] && expected="0x00"
    local addr attempts actual ok
    for addr in 0x58 0x5B; do
        ok=0
        for attempts in 1 2 3; do
            i2cset -y -f "$I2C_BUS" "$addr" 0x01 "$expected" 2>/dev/null || true
            actual=$(i2cget -y -f "$I2C_BUS" "$addr" 0x01 2>/dev/null)
            [ "$actual" = "$expected" ] && { ok=1; break; }
            sleep 0.15
        done
    done
    [ "$ok" = "1" ] && return 0
    echo "[$(date '+%F %T')] set_amp($mode): 写入失败 (期望 $expected, 0x58=$actual)" >&2
    return 1
}

# ---- 耳机麦克风差分路由修复（es8316） ----
# 根因：耳机麦信号实际在 lin2-rin2（Mux=1），UCM 默认配成 lin1-rin1（Mux=0）→ 静音。
# 在插耳机时强制设回正确路由，并作为 UCM 在开机/插拔时覆盖（alsa-store 被 UCM 重置）的
# 最后一道防线。控件名随编解码器而异：找不到控件时静默跳过，绝不影响功放静音核心功能。
# 注意：Differential Mux / Digital Mic Mux 是"非 simple"控件，只能用 amixer cget/cset
#       探测与设置，scontrols 里查不到，不能用 scontrols 做存在性判断。
HP_MIC_DIFF_MUX=${HP_MIC_DIFF_MUX:-lin2-rin2}

# 探测含目标字样的 ALSA 控件所在声卡号（默认 0）。用 cget 而非 scontrols。
detect_alsa_card() {
    local c
    for c in 0 1 2 3; do
        amixer -c "$c" cget name='Differential Mux' >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    echo 0
}
ALSA_CARD=${ALSA_CARD:-$(detect_alsa_card)}

# 控件存在性探测 + 设置。控件名固定为 'Differential Mux' / 'Digital Mic Mux'
# （es8316 上即此名，其他编解码器若无此控件则 cget 失败、静默跳过）。
set_hp_mic_route() {
    # 控件不存在则跳过（非 es8316 或不支持）
    amixer -c "$ALSA_CARD" cget name='Differential Mux' >/dev/null 2>&1 || {
        echo "[$(date '+%F %T')] 未找到 Differential Mux 控件（声卡=$ALSA_CARD），跳过耳机麦路由修复" >&2
        return 0
    }
    amixer -c "$ALSA_CARD" cset name='Differential Mux' "$HP_MIC_DIFF_MUX" >/dev/null 2>&1 || true
    # Digital Mic Mux='dmic disable' 才不静音耳机麦（其余值会静音）；无此控件则忽略
    amixer -c "$ALSA_CARD" cget name='Digital Mic Mux' >/dev/null 2>&1 && \
        amixer -c "$ALSA_CARD" cset name='Digital Mic Mux' 'dmic disable' >/dev/null 2>&1 || true
    echo "[$(date '+%F %T')] 耳机麦路由：Differential Mux='$HP_MIC_DIFF_MUX' (声卡=$ALSA_CARD)" >&2
}

# GPIO 供电（仅老机型）
[ "$NEEDS_GPIO" = "1" ] && [ -n "$GPIO_LINE" ] && {
    gpioset -c "$GPIOCHIP" "$GPIO_LINE"=1 2>/dev/null &
    sleep 0.5
}

# 初始状态：从 input event 设备的当前 SW_HEADPHONE_INSERT 状态读取
# 不能依赖功放寄存器反推（BIOS 可能给半初始化值如 0x38，导致误判）
# 读取方法：用 EVIOCGSW ioctl 获取当前 switch 状态
read_initial_jack_state() {
    python3 - "$JACK_INPUT_DEV" <<'PYEOF'
import sys, os, fcntl, struct
dev = sys.argv[1]
EVIOCGSW = 0x8018451b  # _IOR('E', 0x1b, 32 bytes)
try:
    f = os.open(dev, os.O_RDONLY)
    buf = bytearray(32)
    fcntl.ioctl(f, EVIOCGSW, buf)
    os.close(f)
    # SW_HEADPHONE_INSERT = bit 2
    if buf[0] & 0x04:
        print("on")
    else:
        print("off")
except Exception:
    print("off")
PYEOF
}

PREV=$(read_initial_jack_state)
if [ "$PREV" = "on" ]; then
    _init_target=0
else
    _init_target=1
fi

# 强制对齐功放状态：无论 BIOS 给的初始值是什么（可能是半初始化 0x38），
# 都重写一次为期望值，避免右声道未开等问题。
# 不加 sleep，开机时无 DAPM 竞争。
set_amp "$_init_target" >/dev/null 2>&1
# 开机即应用耳机麦路由（覆盖 UCM 在开机阶段对 alsa-store 的重置）
set_hp_mic_route
echo "[$(date '+%F %T')] 启动：I2C_BUS=$I2C_BUS  NEEDS_GPIO=$NEEDS_GPIO  INPUT=$JACK_INPUT_DEV  jack=$PREV  功放已对齐→$_init_target" >&2

cleanup() {
    [ "$NEEDS_GPIO" = "1" ] && pkill -9 -f "gpioset -c ${GPIOCHIP}.*${GPIO_LINE}" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# ---- 主循环：Python 监听 input event，回调 shell 写功放 ----
# 用进程替换 < <() 避免 subshell 丢变量
# 无 jack 设备（声卡未加载/失败）时跳过监听；监听中设备被移除时
# Python 会退出（不空转），同样落到轮询兜底。
if [ -z "$JACK_INPUT_DEV" ] || [ ! -e "$JACK_INPUT_DEV" ]; then
    echo "[$(date '+%F %T')] 未找到耳机 jack input 设备（声卡可能未就绪），跳过监听" >&2
else
while read -r _marker state _rest; do
    [ "$_marker" = "JACK_STATE" ] || continue
    [ "$state" = "$PREV" ] && continue
    sleep "$AMP_SETTLE_DELAY"
    if [ "$state" = "on" ]; then
        set_amp 0 && echo "[$(date '+%F %T')] 插耳机：扬声器静音 (功放=0x00)" >&2
        # 插耳机时强制校正差分路由，防御 PipeWire/UCM 在插拔瞬间重置
        set_hp_mic_route
    else
        set_amp 1 && echo "[$(date '+%F %T')] 拔耳机：扬声器出声 (功放=0x69)" >&2
    fi
    PREV="$state"
done < <(
python3 - "$JACK_INPUT_DEV" <<'PYEOF'
import sys, os, struct, select
dev = sys.argv[1]
fmt, ev, sw = "=qqHHi", 0x05, 0x02
sz = struct.calcsize(fmt)
try:
    # 用 os.open + os.read（无缓冲）而非 open/f.read（带缓冲）。
    # 带缓冲的 open 会在 select 唤醒后一次性读入多个 input_event 到
    # Python 缓冲，但 select 只监控底层 fd，缓冲内剩余事件不被感知，
    # 导致拔耳机事件延迟到下次插入时才被处理（扬声器无法及时出声）。
    f = os.open(dev, os.O_RDONLY) if os.access(dev, os.R_OK) else None
except Exception:
    f = None
if f is None:
    print("ERR open %s" % dev, file=sys.stderr)
    sys.exit(1)
while True:
    try:
        # 超时 30s 仅作为空转唤醒间隔；设备被移除时 select 会立即
        # 返回（POLLERR），不依赖超时来检测。
        r, _, _ = select.select([f], [], [], 30.0)
    except InterruptedError:
        continue
    except Exception:
        break  # fd 失效（设备被移除）→ 退出，交 shell 轮询兜底
    if not r:
        continue
    try:
        d = os.read(f, sz)
        if not d:
            break  # EOF / 设备移除
        if len(d) < sz:
            continue  # 短读：下轮 select 再取剩余数据
        _, _, t, c, v = struct.unpack(fmt, d)
        if t == ev and c == sw:
            s = "on" if v == 1 else "off"
            sys.stdout.write("JACK_STATE %s\n" % s)
            sys.stdout.flush()
    except OSError:
        break  # ENODEV/EIO（设备已删除）→ 退出，交 shell 轮询兜底
PYEOF
)
fi

# 如果主通道退出（设备缺失或运行中被移除），最后兜底：5 秒轮询，
# 并每 60 秒重新探测 jack 设备（声卡恢复后自动重启监听）。
echo "[$(date '+%F %T')] 主监听结束，进入 5 秒轮询兜底" >&2
_n=0
while true; do
    sleep 5
    _n=$((_n + 1))
    # 每 15 秒重新探测 jack 设备（声卡 probe 可能晚于服务启动，
    # 恢复后尽快重新初始化监听）。
    if [ $((_n % 3)) -eq 0 ]; then
        _newdev=$(detect_input_jack_dev)
        if [ -n "$_newdev" ]; then
            echo "[$(date '+%F %T')] 检测到 jack 设备 $_newdev，重新初始化监听" >&2
            exec "$0"
        fi
    fi
    cur=$(i2cget -y -f "$I2C_BUS" 0x58 0x01 2>/dev/null)
    [ -z "$cur" ] && continue
    if [ "$cur" = "0x00" ] && [ "$PREV" != "on" ]; then
        sleep "$AMP_SETTLE_DELAY"; set_amp 0; PREV="on"
    elif [ "$cur" != "0x00" ] && [ "$PREV" != "off" ]; then
        sleep "$AMP_SETTLE_DELAY"; set_amp 1; PREV="off"
    fi
done
