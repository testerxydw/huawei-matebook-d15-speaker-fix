#!/bin/bash
# 华为 MateBook HWSP0001 功放最小化控制脚本
#
# 功能（仅2项）：
#   1) 插耳机 → 写功放 0x58/0x5B 寄存器 0x01 = 0x00 → 扬声器不出声
#   2) 拔耳机 → 写功放 0x58/0x5B 寄存器 0x01 = 0x69 → 扬声器出声
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
detect_input_jack_dev() {
    local d
    for d in /dev/input/event*; do
        [ -r "$d" ] || continue
        if udevadm info --query=property --name="$d" 2>/dev/null | grep -q "EV_SW.*02\|SW_HEADPHONE_INSERT"; then
            echo "$d"; return 0
        fi
    done
    for d in /dev/input/by-path/*Headset*; do [ -r "$d" ] && { readlink -f "$d"; return 0; }; done
    echo /dev/input/event10
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
    CUR_AMP=0; _init_target=0
else
    CUR_AMP=1; _init_target=1
fi

# 强制对齐功放状态：无论 BIOS 给的初始值是什么（可能是半初始化 0x38），
# 都重写一次为期望值，避免右声道未开等问题。
# 不加 sleep，开机时无 DAPM 竞争。
set_amp "$_init_target" >/dev/null 2>&1
echo "[$(date '+%F %T')] 启动：I2C_BUS=$I2C_BUS  NEEDS_GPIO=$NEEDS_GPIO  INPUT=$JACK_INPUT_DEV  jack=$PREV  功放已对齐→$_init_target" >&2

cleanup() {
    [ "$NEEDS_GPIO" = "1" ] && pkill -9 -f "gpioset -c ${GPIOCHIP}.*${GPIO_LINE}" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# ---- 主循环：Python 监听 input event，回调 shell 写功放 ----
# 用进程替换 < <() 避免 subshell 丢变量
while read -r _marker state _rest; do
    [ "$_marker" = "JACK_STATE" ] || continue
    [ "$state" = "$PREV" ] && continue
    sleep "$AMP_SETTLE_DELAY"
    if [ "$state" = "on" ]; then
        set_amp 0 && CUR_AMP=0 && echo "[$(date '+%F %T')] 插耳机：扬声器静音 (功放=0x00)" >&2
    else
        set_amp 1 && CUR_AMP=1 && echo "[$(date '+%F %T')] 拔耳机：扬声器出声 (功放=0x69)" >&2
    fi
    PREV="$state"
done < <(
python3 - "$JACK_INPUT_DEV" <<'PYEOF'
import sys, os, struct, select, time
dev = sys.argv[1]
fmt, ev, sw = "=qqHHi", 0x05, 0x02
sz = struct.calcsize(fmt)
try:
    f = open(dev, "rb") if os.access(dev, os.R_OK) else None
except Exception:
    f = None
if f is None:
    print("ERR open %s" % dev, file=sys.stderr)
    sys.exit(1)
while True:
    try:
        r, _, _ = select.select([f], [], [], 1.0)
    except InterruptedError:
        r = []
    if not r:
        continue
    try:
        d = f.read(sz)
        if len(d) < sz:
            f.close(); time.sleep(1)
            f = open(dev, "rb"); continue
        _, _, t, c, v = struct.unpack(fmt, d)
        if t == ev and c == sw:
            s = "on" if v == 1 else "off"
            sys.stdout.write("JACK_STATE %s\n" % s)
            sys.stdout.flush()
    except Exception:
        pass
PYEOF
)

# 如果主通道退出（Python 异常退出），最后兜底：5 秒轮询
echo "[$(date '+%F %T')] 主监听退出，进入 5 秒轮询兜底" >&2
while true; do
    sleep 5
    cur=$(i2cget -y -f "$I2C_BUS" 0x58 0x01 2>/dev/null)
    [ -z "$cur" ] && continue
    if [ "$cur" = "0x00" ] && [ "$PREV" != "on" ]; then
        sleep "$AMP_SETTLE_DELAY"; set_amp 0; PREV="on"
    elif [ "$cur" != "0x00" ] && [ "$PREV" != "off" ]; then
        sleep "$AMP_SETTLE_DELAY"; set_amp 1; PREV="off"
    fi
done
