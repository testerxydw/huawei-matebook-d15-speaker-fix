# Huawei MateBook D15 (BoF-XX) Speaker / Headphone Auto-Switch Fix

> Target: Huawei MateBook D15 `BoF-XX` (same family as `BOD-WXX9`, all using the ES8336 codec + HWSP0001 speaker amplifier).
> This solution is **entirely in user space — no kernel recompilation required**.
> The initial code comes from the upstream project [MaximushkaBed/huawei-matebook-d15-speaker-fix](https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix). The upstream fixed the "speaker always silent" issue on HWSP0001 under Linux; this repo additionally adds headphone plug/unplug auto-mute/restore linkage, plus auto-detection, pop protection, and kernel-independence verification.

## 1. Background

- The **speaker** is driven by the `HWSP0001` amplifier (I2C bus auto-detected at runtime, `i2c-3` on this board, addresses `0x58`/`0x5B`); the **headphone** uses the `ES8336` codec's independent path. They are independent.
- `HWSP0001` has no Linux driver: on BoF-XX the amplifier boots muted and must be enabled by replaying a set of I2C "enable" registers (`reinit_amp`).
- The amplifier provides a **soft-mute register `0x01`**:
  - Write `0x00` → **mutes the speaker only**; the headphone keeps playing (verified).
  - Write `0x69` → restores the speaker.
- Plug/unplug can be observed from user space via `alsactl monitor hw:0` on the ALSA `Headphone Jack` control.

**The bug**: the auto script used to toggle the amplifier power GPIO (`gpio-145`) to mute the speaker on headphone insert, but on this machine that does not actually silence the speaker — hence "speaker still plays when headphones are inserted / speaker keeps playing when booting with headphones plugged".

**Fix**: change the "mute speaker" action to write the amplifier soft-mute register `0x01=0x00` (speaker only, headphone unaffected), executed automatically by the script on plug/unplug.

## 2. Specific Fix

Only `huawei-speaker-mute.sh`'s `set_amp()` was changed (logic otherwise unchanged):

- **Enable speaker (`val=1`)**: keep the amplifier power GPIO (`gpio-145`) on and call `reinit_amp()` to replay enable registers (un-mute).
- **Disable speaker (`val=0`, i.e. on headphone insert)**: instead of toggling `gpio-145`, write the soft-mute register:
  ```bash
  i2cset -y -f "$I2C_BUS" 0x58 0x01 0x00   # soft-mute left amplifier
  i2cset -y -f "$I2C_BUS" 0x5B 0x01 0x00   # soft-mute right amplifier
  ```
  This mutes only the speaker; the headphone (ES8336 path) is unaffected.
- `apply()` is unchanged: `jack=on` → `set_amp 0` (speaker muted); `jack=off` → `set_amp 1` (speaker restored) and `unplug_volume_guard` zeroes the PipeWire/ALSA speaker volume first (no pop), which the user can then raise.

> Note: an in-kernel alternative was explored earlier (a `JD_INVERTED` quirk for the `es8336` codec driver, in `es8336-jack-invert/`). Because plug/unplug is already reliably observable from user space and the amplifier soft-mute achieves the same result, **the user-space script is the chosen solution** — simpler and instantly reversible, no kernel module build.

## 3. Fix Steps (Deploy)

1. Install the script and systemd service (as root):
   ```bash
   sudo ./install.sh
   ```
   This installs `huawei-speaker-mute.sh` to `/usr/local/bin/` (falls back to `/opt/` if not writable) and enables `huawei-speaker-mute.service` (auto-starts, auto-monitors plug/unplug). On this machine the installed path is `/opt/huawei-speaker-mute.sh`.
2. Apply immediately (no reboot needed):
   ```bash
   sudo systemctl restart huawei-speaker-mute.service
   ```
3. Confirm it is running:
   ```bash
   systemctl status huawei-speaker-mute.service
   ```

Manual control (independent of auto-monitoring) is also supported:
```bash
huawei-speaker-mute.sh mute     # soft-mute speaker (same as headphone inserted)
huawei-speaker-mute.sh unmute   # restore speaker
huawei-speaker-mute.sh status   # show amplifier 0x01 register state
```

## 4. Verification Criteria

All of the following must hold for the fix to be considered successful:

| Scenario | Expected | Pass when |
|----------|----------|-----------|
| **Headphone inserted** | Speaker **silent**; headphone **audible** | Speaker muted, headphone works |
| **Headphone removed** | Speaker **audible again** (muted first, then user raises volume) | Speaker returns after unplug |
| **Boot with headphone plugged** | Speaker **silent** at startup | No speaker sound when booting plugged-in |
| **Boot without headphone** | Speaker **audible** | Normal speaker output |
| **No pops during switch** | Volume zeroed before restore on unplug | No loud "pop" |

Helper checks:
```bash
huawei-speaker-mute.sh status                       # prints 0x01 of 0x58/0x5B (0x00=muted, 0x69=restored)
i2cget -y -f <I2C_BUS> 0x58 0x01                    # <I2C_BUS> auto-detected (i2c-3 here); 0x00 inserted / 0x69 removed
alsactl monitor hw:0                                # observe Headphone Jack flips on plug/unplug
```

If any check fails, verify: ① service is running; ② `Headphone Jack` actually flips on plug/unplug; ③ `i2cset` can reach `0x58/0x5B` (needs root).

## 5. Rollback

- Stop auto-switching: `sudo systemctl stop huawei-speaker-mute.service`.
- Fully uninstall: reverse of `install.sh` (remove `/usr/local/bin/huawei-speaker-mute.sh` and disable the service).
- No kernel is modified, so rollback leaves no residual risk.

## 6. Kernel-Independence Verification (no kernel changes)

This fix **does not modify any kernel file, kernel config, or kernel module**. Evidence:

1. **No custom kernel module built/installed**: the stock `snd-soc-es8336.ko.zst` remains at `/lib/modules/$(uname -r)/kernel/sound/soc/codecs/`; no `es83xx` custom module exists under `/updates` or `/extra`; `dkms status` shows only `deepin-anything` (unrelated).
2. **Kernel config unchanged**: a `diff` of the running `/proc/config.gz` against the distro's original `/boot/config-$(uname -r)` returns **identical (KERNEL_CONFIG_IDENTICAL)**. Key options such as `CONFIG_MODULE_FORCE_UNLOAD` (unset, consistent with our earlier failed `rmmod -f`) and `CONFIG_SND_SOC_ES8336=m` are distro defaults.
3. **Source change scope**: `git diff` shows only the user-space script `huawei-speaker-mute.sh` and the two READMEs changed; the earlier `es8336-jack-invert/` exploration directory was deleted with no residue.
4. **Implementation**: the whole fix is achieved only via user-space I2C register writes (`i2cset`) plus ALSA control monitoring (`alsactl monitor`) — no kernel module support is required.

**Conclusion: the fix is fully independent of the kernel layer and can be applied directly to any similar system that has not modified its kernel, with instant rollback and zero residue.**

## 7. Portability / Generality Assessment

**The core idea is reusable, but the script itself targets HWSP0001 and cannot be used on other devices as-is.** Two layers:

### Reusable framework (hardware-independent)
- Monitor plug/unplug via `alsactl monitor` on the `Headphone Jack` control;
- On transitions, mute/restore the speaker volume through PipeWire (`wpctl`, as the desktop user) to avoid pops;
- A systemd service keeps it resident and starts at boot.

This "user-space plug/unplug monitor → control amplifier/volume" pattern applies to any Linux device with abnormal speaker/headphone switching that you want to fix with a soft approach.

### Device-specific parts (must be adapted per hardware)
- `detect_i2c()` relies on the `i2c-HWSP0001:00` ACPI device name — other amplifiers won't have this node and detection will fail and exit;
- `set_amp()`'s soft-mute register (`0x01=0x00`), enable-register sequence (`reinit_amp`), and I2C addresses (`0x58/0x5B`) are all HWSP0001-specific;
- `detect_gpio()` parses the `GNUM()` argument of the HWSP device in the DSDT to get the amplifier power GPIO line — also model-specific.

### Conditions to port to another device
To reuse this approach on another machine you need:
1. The speaker amplifier is reachable over I2C (or similar writable interface) and has a "soft-mute" register;
2. The headphone uses a path independent of the speaker amplifier (soft-muting the speaker must not also mute the headphone) — satisfied here by the independent ES8336 path;
3. A monitorable plug/unplug event source exists in the system (ALSA `Headphone Jack`, or some GPIO/input event).

When these hold, you only need to replace the I2C bus/address/register values in `set_amp()`, the init sequence in `reinit_amp()`, and (if still GPIO-dependent) the `detect_gpio()` parsing — then the script framework is reusable.

**Conclusion**: `huawei-speaker-mute.sh` is a finished fix for HWSP0001 machines; it is not a turnkey universal tool, but its "monitor plug/unplug + soft-mute amplifier + volume protection" architecture can be used directly as a template for other similar devices.
