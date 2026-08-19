#!/usr/bin/env python3
# 诊断：监听 event10 原始 EV_SW 事件 + 0.2s 轮询 EVIOCGSW 状态
# 目的：确定"拔出耳机"时内核到底有没有产生事件/状态变化
import sys, os, struct, select, time, fcntl

dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/input/event10"
fmt = "=qqHHi"          # input_event: timeval(qq) type(H) code(H) value(i)
sz = struct.calcsize(fmt)
EVIOCGSW = 0x8018451b   # 读 switch 位图

f = open(dev, "rb")

def read_sw_state(fd):
    buf = bytearray(32)
    fcntl.ioctl(fd, EVIOCGSW, buf)
    return "on" if (buf[0] & 0x04) else "off"   # SW_HEADPHONE_INSERT = bit2

start = time.time()
last_poll_state = read_sw_state(f.fileno())
print("[%8.3f] 初始状态: %s   (请开始拔插)" % (0.0, last_poll_state), flush=True)

while True:
    r, _, _ = select.select([f], [], [], 0.2)
    now = time.time() - start
    if r:
        try:
            d = f.read(sz)
            if len(d) >= sz:
                _, _, t, c, v = struct.unpack(fmt, d)
                if t == 0x05 and c == 0x02:  # EV_SW + SW_HEADPHONE_INSERT
                    print("[%8.3f] EV_SW事件: value=%d (%s)" % (now, v, "on" if v else "off"), flush=True)
        except Exception as e:
            print("[%8.3f] read错误: %s" % (now, e), flush=True)
    # 每 0.2s 轮询一次当前状态
    try:
        cur = read_sw_state(f.fileno())
    except Exception:
        cur = "?"
    if cur != last_poll_state:
        print("[%8.3f] 轮询: 状态=%s" % (now, cur), flush=True)
        last_poll_state = cur
