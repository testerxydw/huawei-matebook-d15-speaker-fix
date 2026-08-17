#!/usr/bin/env python3
# 临时诊断：轮询 ES8336/ES8316 codec 寄存器，定位插拔时哪个寄存器变化
import fcntl, time, sys

I2C_SLAVE_FORCE = 0x0706
BUS = '/dev/i2c-1'
ADDR = 0x10
# 覆盖 GEN_CTRL + JD CTRL 及其周边可能的 status 寄存器
REGS = [0x00, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x26, 0x27, 0x28, 0x30, 0x31, 0x32]

try:
    f = open(BUS, 'rb+', buffering=0)
    fcntl.ioctl(f, I2C_SLAVE_FORCE, ADDR)
except Exception as e:
    print(f'无法打开 {BUS}: {e}'); sys.exit(1)

def rd(reg):
    f.write(bytes([reg]))
    time.sleep(0.001)
    return f.read(1)[0]

prev = {}
for r in REGS:
    try:
        prev[r] = rd(r)
    except Exception:
        prev[r] = None
print('初始寄存器:', ' '.join(f'{r:#04x}={prev[r]:#04x}' if prev[r] is not None else f'{r:#04x}=ERR' for r in REGS), flush=True)

end = time.time() + 40
changes = 0
while time.time() < end:
    for r in REGS:
        try:
            v = rd(r)
        except Exception:
            continue
        if prev[r] is not None and v != prev[r]:
            print(f'[{time.strftime("%H:%M:%S")}] reg {r:#04x}: {prev[r]:#04x} -> {v:#04x}', flush=True)
            prev[r] = v
            changes += 1
    time.sleep(0.15)

print(f'监控结束，共检测到 {changes} 处寄存器变化', flush=True)
