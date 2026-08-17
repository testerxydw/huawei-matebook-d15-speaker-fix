#!/usr/bin/env python3
# 实时监控 alsactl 事件 + 同步读取 Jack 控件值,验证事件与值变化是否一致
import subprocess, time, sys

def read_jack():
    try:
        out = subprocess.run(['amixer','-c','0','cget','numid=27'],
                           capture_output=True, text=True).stdout
        for line in out.splitlines():
            if ': values=' in line:
                return line.split('values=')[-1].strip()
    except:
        pass
    return '?'

def read_mic_jack():
    try:
        out = subprocess.run(['amixer','-c','0','cget','numid=28'],
                           capture_output=True, text=True).stdout
        for line in out.splitlines():
            if ': values=' in line:
                return line.split('values=')[-1].strip()
    except:
        pass
    return '?'

print(f'初始状态: Headphone Jack={read_jack()}, Headset Mic Jack={read_mic_jack()}')
print('>>> 请插拔耳机,观察事件与值是否同步 <<<')
print()

# 用 stdbuf 强制行缓冲,避免 alsactl 输出到管道时块缓冲导致事件滞留/丢失
proc = subprocess.Popen(['stdbuf','-oL','-eL','alsactl','monitor','hw:0'],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

for line in proc.stdout:
    line = line.strip()
    if not line:
        continue
    
    # 只关注 Jack 相关事件
    if 'Headphone Jack' in line or 'Headset Mic Jack' in line:
        timestamp = time.strftime('%H:%M:%S')
        print(f'[{timestamp}] 事件: {line}')
        
        # 事件后立即读取值
        time.sleep(0.05)
        hp = read_jack()
        mic = read_mic_jack()
        print(f'           → 当前值: Headphone Jack={hp}, Headset Mic Jack={mic}')
        print()
