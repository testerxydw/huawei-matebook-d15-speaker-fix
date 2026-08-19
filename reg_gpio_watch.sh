#!/bin/bash
# 监控 v3: gpio81电平 | irq计数 | GPIO_FLAG(0x4f) | jack状态
prev=""
echo "监控启动：gpio81 | irq计数 | 0x4f | jack"
while true; do
    t=$(date '+%H:%M:%S.%3N')
    g81=$(sudo grep -E "^ gpio-81" /sys/kernel/debug/gpio 2>/dev/null | grep -oE '\b(hi|lo)\b' | head -1)
    irq=$(grep " es8316$" /proc/interrupts | awk '{for(i=2;i<=17;i++) sum+=$i} END{print sum}')
    r4f=$(sudo /usr/sbin/i2cget -y -f 1 0x10 0x4f 2>/dev/null | sed 's/^0x//')
    jack=$(sudo python3 -c "
import os, fcntl
f = os.open('/dev/input/event10', os.O_RDONLY)
buf = bytearray(32)
fcntl.ioctl(f, 0x8018451b, buf)
print('on' if buf[0] & 0x04 else 'off')
os.close(f)" 2>/dev/null)
    cur="$g81|$irq|$r4f|$jack"
    if [ "$cur" != "$prev" ]; then
        echo "[$t] gpio81=$g81 irq=$irq 0x4f=$r4f jack=$jack"
        prev="$cur"
    fi
    sleep 0.2
done
