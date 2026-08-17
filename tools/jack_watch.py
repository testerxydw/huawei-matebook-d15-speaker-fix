#!/usr/bin/env python3
# 临时诊断脚本：监听耳机插拔的真实事件通道(input EV_SW)，并对照 ALSA 控件值
import struct, glob, os, sys, subprocess

def find_jack_dev():
    for ev in glob.glob('/sys/class/input/event*'):
        try:
            name = open(os.path.join(ev, 'device/name')).read().strip()
            sw = open(os.path.join(ev, 'device/capabilities/sw')).read().strip()
            if int(sw, 16) & (1 << 2):  # SW_HEADPHONE_INSERT
                return '/dev/input/' + os.path.basename(ev), name
        except Exception:
            continue
    return None, None

def read_alsa_jack():
    try:
        out = subprocess.run(['amixer','-c','0','cget','numid=27'],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if 'values=' in line and ':' in line:
                return line.split('values=')[-1].strip()
    except Exception:
        pass
    return '?'

dev, name = find_jack_dev()
if not dev:
    print('未找到支持 SW_HEADPHONE_INSERT 的 input 设备'); sys.exit(1)
print(f'监听设备: {dev} ({name})  [Ctrl+C 或超时退出]', flush=True)
print(f'初始 ALSA Headphone Jack = {read_alsa_jack()}', flush=True)

f = open(dev, 'rb')
while True:
    buf = f.read(24)
    if len(buf) < 24:
        continue
    typ, code, val = struct.unpack('16xHHi', buf)
    if typ == 0x05:  # EV_SW
        nm = {0x02: '耳机插入开关', 0x04: '麦克风插入开关'}.get(code, f'SW_{code}')
        st = '插入(1)' if val else '拔出(0)'
        print(f'[input SW] {nm} -> {st}  | ALSA Jack={read_alsa_jack()}', flush=True)
