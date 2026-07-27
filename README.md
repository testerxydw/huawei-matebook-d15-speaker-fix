# Huawei MateBook D15 — Speaker/Headphone Auto-Switch Fix for Linux

Fixes simultaneous audio output from both speakers and headphones on Huawei MateBook D15 (BOD-WXX9) running Linux. After applying this fix, speakers mute automatically when headphones are plugged in, and **restore correctly when headphones are unplugged** — no reboot required.

## Affected Hardware

| Field | Value |
|-------|-------|
| Laptop | Huawei MateBook D15 |
| Board | BOD-WXX9-PCB-B4 (orig), **BoF-XX / BoF-XX-PCB** (this device) |
| Tested OS | Ubuntu 24.04 LTS, kernel 6.17.0-23-generic (BOD); rolling kernel 6.18 (BoF-XX) |
| Audio codec | Everest Semi ES8336 (ACPI: ESSX8336) |
| Speaker amp | Huawei custom HWSP0001 (no Linux driver) |

The script **auto-detects every board-specific parameter at runtime** — the I2C
bus, the Headphone-Jack ALSA control, the speaker volume control, and even the
amp-enable **GPIO line** (decoded from the DSDT via `iasl`, see
[GPIO line](#gpio-line)). No manual editing is required for either board.

May also work on other MateBook models with HWSP0001 — see [Compatibility](#compatibility).

## The Problem

Linux has no driver for the `HWSP0001` speaker amplifier. The BIOS initializes it once at boot via SMM (before the OS loads), but there is no mechanism in Linux to:
- Mute the speakers when headphones are plugged in
- Re-initialize the amp after it's been powered off

The standard ALSA/DAPM controls, WirePlumber routing, and GPIO tweaks from the `snd_soc_sof_es8336` driver all fail because they don't control the actual amplifier chip.

## How It Works

Through DSDT analysis and I2C register dumping, we identified:

- The speaker amp (`HWSP0001`) sits on an I2C bus at addresses **0x58** (L) and **0x5B** (R), running at 400kHz. The exact bus differs by board: **i2c-2** on BOD-WXX9, **i2c-4** on BoF-XX. The script auto-detects it from `/sys/bus/i2c/devices/i2c-HWSP0001:00`.
- The **amp enable GPIO line** is board-specific (e.g. **267** on BOD-WXX9, **145** on BoF-XX) but is **auto-detected** from the DSDT — see [GPIO line](#gpio-line).
- After a GPIO power cycle (`0 → 1`), the amp comes back alive on I2C but in a default (silent) state
- Writing back the 27 BIOS-initialized register values via `i2cset` fully restores the amp

The fix is a `systemd` service that:
1. Monitors the ALSA Headphone Jack control via `alsactl monitor`
2. Drives the amp-enable GPIO **low** when headphones are inserted (amp off)
3. Drives the GPIO **high** when headphones are removed (amp on), then replays the I2C register initialization
4. On a real unplug event, drives PipeWire (`wpctl`) to **force the speaker volume to 0** before re-powering the amp (avoids a blast); boot / plug-in leave the volume untouched

```
Jack event detected
        │
   jack=on  ──→ gpio=0  (amp OFF, headphones active)
   jack=off ──→ gpio=1  (amp ON)
                    │
                    ▼
             i2cset replay
         27 registers → 0x58 & 0x5B
                    │
                    ▼
           Speakers working ✓
```

## Headphone-unplug Safety (auto volume = 0)

On this hardware a single PipeWire sink drives both the headphone and the
speaker, and **PipeWire owns the volume** — writing the ALSA mixer alone is
immediately overridden by PipeWire. So when you **unplug the headphones**, the
script drives `wpctl` (as your desktop user) to **force the speaker volume to 0**
*before* the amp is re-powered, so it never blasts at the previous headphone
volume; you then raise it manually with your volume keys / mixer.

Boot and headphone plug-in leave the volume **untouched** (your headphone volume
is never clobbered). The volume is only changed on a genuine jack transition.

## Requirements

```bash
sudo apt install i2c-tools gpiod alsa-utils
```

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/huawei-matebook-d15-speaker-fix
cd huawei-matebook-d15-speaker-fix
sudo bash install.sh
```

That's it. The service starts immediately and enables on boot.

## Manual Installation

```bash
sudo cp huawei-speaker-mute.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/huawei-speaker-mute.sh
sudo cp huawei-speaker-mute.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now huawei-speaker-mute.service
```

## Verifying It Works

```bash
sudo systemctl status huawei-speaker-mute.service
```

Plug in headphones → speakers should go silent.  
Unplug headphones → speakers should come back within ~0.5 seconds.

## Compatibility

This fix was developed and tested on **BOD-WXX9-PCB-B4**. It may work on other MateBook models that use the same `HWSP0001` amplifier.

To check if your board has `HWSP0001`:
```bash
ls /sys/bus/acpi/devices/ | grep -i hw
# Should show: HWSP0001:00
```

To check which I2C bus the amp is on (the bus differs by board — i2c-2 on
BOD-WXX9, i2c-4 on BoF-XX):
```bash
readlink -f /sys/bus/i2c/devices/i2c-HWSP0001:00
# BOD-WXX9 -> .../i2c_designware.2/i2c-2/...
# BoF-XX   -> .../i2c_designware.3/i2c-4/...
```
The script auto-detects this, so you normally don't need to set `I2C_BUS`.

### GPIO line

The amp enable GPIO line is **board-specific**, but the script now
**auto-detects it** at startup: it disassembles the DSDT with `iasl` and decodes
the `GNUM(...)` argument of the HWSP device's `_INI` method
(`line = GPCL[group][6] + (arg & 0xFFFF)`). Verified values:
**267** on BOD-WXX9, **145** on BoF-XX. If `iasl` is missing or the decode fails,
it falls back to `GPIO_LINE=145`.

To verify on your own board:

```bash
sudo apt install acpica-tools
sudo iasl -d /sys/firmware/acpi/tables/DSDT
grep -n -A6 'Device (HWSP)' dsdt.dsl
# look for:  PIN1 = GNUM (0x090B00XX)   (BOD)   or   GNUM (0x090800XX) (BoF)
# GPIO line = GPCL[group][6] + 0xXX
#   BOD: 0x090B000B -> GPCL[0x0B][6]=256 + 0x0B = 267
#   BoF: 0x09080001 -> GPCL[0x08][6]=144 + 0x01 = 145
```

All parameters can still be overridden via environment variables (rarely needed):

```bash
GPIOCHIP=gpiochip0
GPIO_LINE=         # empty -> auto-detected from DSDT (fallback 145)
JACK_NUMID=        # empty -> auto-detected from "Headphone Jack"
I2C_BUS=           # empty -> auto-detected from i2c-HWSP0001:00
SPK_VOL_NUMID=     # empty -> auto-detected (DAC/Speaker/Master Playback Volume)
SPK_VOL_DEFAULT=70 # % applied on boot / headphone plug-in
```

**About the register values:** the values in `reinit_amp()` are the HWSP0001
**enable** values (same silicon across BOD-WXX9 / BoF-XX). Important for BoF-XX:
a fresh-boot `i2cdump` on i2c-4 shows the amp's **default *silent* state**, which
matches BOD-WXX9's documented silent-default values — this means BoF-XX's BIOS
does **not** initialize the amp at boot. So you must **NOT** copy a fresh-boot
dump into the script; the script's existing enable values are what actually
produce sound. Only revisit these values if you have a known-good "sound works"
dump from a different board revision.

If you want to inspect the current state, dump on the correct bus:

```bash
# BOD-WXX9:
sudo i2cdump -y -f 2 0x58
sudo i2cdump -y -f 2 0x5B
# BoF-XX (amp is on i2c-4! -- a silent-default dump is expected):
sudo i2cdump -y -f 4 0x58
sudo i2cdump -y -f 4 0x5B
```

## Technical Details

### DSDT Analysis

The HWSP0001 device in ACPI:
- **BOD-WXX9**: `\_SB_.PC00.I2C3.HWSP` — two I2C resources 0x58/0x5B at 400kHz on I2C3; GPIO enable pin via `GNUM(0x090B000B)` → gpio-267
- **BoF-XX**: `\_SB_.PC00.I2C5.HWSP` — same 0x58/0x5B at 400kHz, but on I2C5 (i2c-4); GPIO community is the same Intel PCH, verify the exact line with the method in [GPIO line](#gpio-line)

`_INI` only sets the GPIO pin number in the resource template — it does **not** initialize the amp over I2C

The actual I2C initialization happens in BIOS firmware (SMM) before Linux boots. There is no ACPI method that triggers it.

### Why acpi_call Doesn't Help

After installing `acpi-call-dkms` and inspecting the DSDT, the `_INI` method for HWSP0001 is:
```c
Method (_INI, 0, NotSerialized) {
    PIN1 = GNUM(0x090B000B)  // just writes gpio number into resource template
}
```
No I2C writes. The real init is in BIOS SMM code.

### Register Differences (BIOS init vs default state)

| Register | BIOS value | Default (after power cycle) |
|----------|-----------|---------------------------|
| 0x01 | 0x69 | 0x38 |
| 0x03 | 0x16 | 0x0c |
| 0x04 | 0x80 | 0x00 |
| 0x05 | 0x0c | 0x08 |
| 0x06 | 0x11 | 0x10 |
| 0x07 | 0x93 | 0x43 |
| 0x09 | 0x0b | 0x03 |
| 0x0b | 0x4b | 0x4a |
| 0x0c | 0x00 | 0x03 |
| 0x0d | 0x77 | 0xdd |
| 0x0f | 0x51 | 0x23 |
| 0x10 | 0x58 | 0x08 |
| 0x58 | 0x00 | 0x80 |
| 0x59 | 0x80 | 0x00 |
| 0x61–0x69 | see script | different |
| 0x71–0x74 | see script | different |

## Known Limitations

- The exact chip model behind HWSP0001 is unknown (likely TI TAS25xx or similar). Without a datasheet, we don't know the meaning of each register.
- The register values were captured from one specific board. If your board was manufactured at a different revision or calibrated differently, values may differ.
- The `snd_soc_sof_es8336` DMI quirk patch for BOD-WXX9 (included in some versions of this repo) activates DAPM speaker switching but has no effect on actual sound output — the real amp is HWSP0001, not controlled by the codec driver.

## Contributing

If you have a different MateBook model with HWSP0001, please open an issue with:
- Board model (`cat /sys/class/dmi/id/board_name`)
- Output of `readlink -f /sys/bus/i2c/devices/i2c-HWSP0001:00`
- Your amp register dump (fresh boot, before any jack events)
- GPIO number (from `cat /sys/bus/acpi/devices/HWSP0001:00/path` + DSDT analysis)

## License

MIT
