#!/usr/bin/env python3
# 纯值轮询:不依赖任何事件机制,直接每0.15秒读取 Jack 控件值,值变化即打印
import subprocess, time

def read_ctl(numid):
    try:
        out = subprocess.run(['amixer','-c','0','cget',f'numid={numid}'],
                           capture_output=True, text=True).stdout
        for line in out.splitlines():
            if ': values=' in line:
                return line.split('values=')[-1].strip()
    except Exception:
        pass
    return '?'

prev_hp = read_ctl(27)
prev_mic = read_ctl(28)
print(f'初始: Headphone Jack={prev_hp}, Headset Mic Jack={prev_mic}')
print('>>> 请插拔耳机,值一旦变化会立即打印 <<<')

end = time.time() + 90
while time.time() < end:
    hp = read_ctl(27)
    mic = read_ctl(28)
    if hp != prev_hp:
        print(f'[{time.strftime("%H:%M:%S")}] Headphone Jack: {prev_hp} -> {hp}', flush=True)
        prev_hp = hp
    if mic != prev_mic:
        print(f'[{time.strftime("%H:%M:%S")}] Headset Mic Jack: {prev_mic} -> {mic}', flush=True)
        prev_mic = mic
    time.sleep(0.15)
print('轮询结束(90秒)')
