#!/bin/bash
# Huawei MateBook speaker amp (HWSP0001) jack-aware mute/switch fix
#
# The HWSP0001 amplifier has no Linux driver. The BIOS initializes it once at
# boot via SMM, but Linux cannot mute it on headphone insertion or re-init it
# after a GPIO power cycle. This script watches the ALSA Headphone Jack control
# and toggles the amp enable GPIO, replaying the BIOS register init when the
# amp is powered back on.
#
# I2C bus and the Headphone-Jack ALSA control are auto-detected at runtime so
# the script works on both BOD-WXX9 (i2c-2) and BoF-XX (i2c-4) boards. The amp
# enable GPIO line is board-specific -- see GPIO_LINE below.

# ---------- configurable (env overrides) ----------
GPIOCHIP=${GPIOCHIP:-gpiochip0}
GPIO_LINE=${GPIO_LINE:-145}   # BoF-XX amp-enable GPIO: GNUM(0x09080001) = GPCL[0x08][6] + 1 = 145
                               # BOD-WXX9 uses 267; override with GPIO_LINE env if needed
JACK_NUMID=${JACK_NUMID:-}    # auto-detected from "Headphone Jack" if empty
I2C_BUS=${I2C_BUS:-}          # auto-detected from i2c-HWSP0001:00 if empty
# ------------------------------------------------

# The amp-enable GPIO line is decoded from the HWSP _INI "PIN1 = GNUM(...)"
# argument. GNUM() returns the controller-relative line on \_SB.GPI0, which is
# exactly the value to pass to gpioset. For BoF-XX: GNUM(0x09080001) -> 145.
# Auto-detection from the binary DSDT is impractical (the GPCL base table lives
# in ASL text / an SSDT), so the line is set per board above.

# Auto-detect I2C bus from the HWSP0001 ACPI/I2C device.
if [ -z "$I2C_BUS" ]; then
    link=$(readlink -f /sys/bus/i2c/devices/i2c-HWSP0001:00 2>/dev/null)
    if [ -n "$link" ]; then
        I2C_BUS=$(printf '%s' "$link" | grep -oE 'i2c-[0-9]+' | head -1 | cut -d- -f2)
    fi
fi
if [ -z "$I2C_BUS" ]; then
    echo "ERROR: cannot find HWSP0001 I2C bus; set I2C_BUS manually." >&2
    exit 1
fi

# Auto-detect the Headphone Jack ALSA control numid.
if [ -z "$JACK_NUMID" ]; then
    JACK_NUMID=$(amixer -c 0 controls 2>/dev/null \
        | sed -n 's/.*numid=\([0-9]*\).*name=.Headphone Jack.*/\1/p' | head -1)
fi
if [ -z "$JACK_NUMID" ]; then
    echo "ERROR: cannot find 'Headphone Jack' control; set JACK_NUMID manually." >&2
    exit 1
fi

echo "Using I2C_BUS=$I2C_BUS  JACK_NUMID=$JACK_NUMID  GPIO $GPIOCHIP line $GPIO_LINE"

CURRENT_PID=

# Replay the HWSP0001 "enable" register values over I2C to bring the amp to
# life. These are the amplifier's enable values (same silicon across BOD-WXX9
# and BoF-XX). NOTE: on BoF-XX the BIOS leaves the amp in its default *silent*
# state at boot (a fresh `i2cdump` there shows the silent defaults, NOT these
# values), so writing these enable values is exactly what makes sound work.
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

set_amp() {
    local val=$1
    if [ -n "$CURRENT_PID" ]; then
        kill "$CURRENT_PID" 2>/dev/null
        wait "$CURRENT_PID" 2>/dev/null
    fi
    # Hold the GPIO enable line at $val for the whole session (libgpiod v2:
    # -c selects the chip; the trailing & keeps gpioset running so the line
    # stays driven until the process is killed on the next jack event).
    gpioset -c "$GPIOCHIP" "$GPIO_LINE=$val" &
    CURRENT_PID=$!
    if [ "$val" = "1" ]; then
        reinit_amp
    fi
}

read_jack() {
    amixer -c 0 cget "numid=$JACK_NUMID" 2>/dev/null \
        | sed -n 's/^[[:space:]]*: values=//p'
}

apply() {
    local jack
    jack=$(read_jack)
    if [ "$jack" = "on" ]; then
        set_amp 0
    else
        set_amp 1
    fi
}

cleanup() {
    [ -n "$CURRENT_PID" ] && kill "$CURRENT_PID" 2>/dev/null
    exit 0
}

trap cleanup TERM INT
apply
alsactl monitor hw:0 2>/dev/null | while read -r _; do
    apply
done
