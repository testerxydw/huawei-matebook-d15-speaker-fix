# Huawei MateBook D15 (BoF-XX) Speaker / Headphone Auto-Switch Fix

> Target: Huawei MateBook D15 `BoF-XX` (same family as `BOD-WXX9`, all using the ES8336 codec + HWSP0001 speaker amplifier).
> This solution is **entirely in user space — no kernel recompilation required**.
> The initial code comes from the upstream project [MaximushkaBed/huawei-matebook-d15-speaker-fix](https://github.com/MaximushkaBed/huawei-matebook-d15-speaker-fix). The upstream fixed the "speaker always silent" issue on HWSP0001 under Linux; this repo additionally adds headphone plug/unplug auto-mute/restore linkage, plus auto-detection, pop protection, and kernel-independence verification.

## 1. Background

- The **speaker** is driven by the `HWSP0001` amplifier (I2C bus auto-detected at runtime, `i2c-3` on this board, addresses `0x58`/`0x5B`); the **headphone** uses the `ES8336` codec's independent path. They are independent.
- `HWSP0001` has no Linux driver: the amplifier boots muted and must be enabled by replaying a set of I2C "enable" registers (`reinit_amp`).
- The amplifier provides a **soft-mute register `0x01`**:
  - Write `0x00` → **mutes the speaker only**; the headphone keeps playing (verified).
  - Write `0x69` → restores the speaker.
- Plug/unplug is observed via a **three-tier monitor** (see §2): the primary channel is the input event device created by the `sof_es8336` driver (`/dev/input/eventN`, `SW_HEADPHONE_INSERT`), backed by periodic polling and `alsactl monitor`.

**Model difference (key)**: whether the amplifier power GPIO must be driven by user space depends on the model, auto-detected via DMI:
- **BoF-XX and similar new boards**: the BIOS already powers the amplifier GPIO at boot. If user space toggles that line with `gpioset`, it breaks the BIOS-established pin state and makes the amplifier I2C permanently inaccessible (reboot required). The script sets `NEEDS_GPIO=0` and **never touches the GPIO**.
- **BOD-WXX9 / BOHB-WAX9 and similar older boards**: the BIOS does not initialize the amplifier GPIO, so user space must keep the power line high with `gpioset` for the amplifier I2C to be accessible. The script sets `NEEDS_GPIO=1`.

**The bug**: the early script toggled the amplifier power GPIO to mute on headphone insert, but that neither truly mutes the speaker (the GPIO is unrelated to amplifier mute) nor is safe on BoF-XX (it breaks the BIOS GPIO state).

**Fix**: change the "mute speaker" action to write the amplifier soft-mute register `0x01=0x00` (speaker only, headphone unaffected), executed automatically by the script on plug/unplug; whether the GPIO is driven by user space is left to the DMI auto-detection.

## 2. Specific Fix

The script `huawei-speaker-mute.sh` does the following at runtime (all in user space):

- **DMI-based GPIO strategy** (`detect_dmi_gpio_needed`): sets `NEEDS_GPIO` from `product_name`. `BoF*` → `0` (do not touch GPIO); `BOD*`/`BOH*` → `1` (user space drives GPIO power). Overridable via the `NEEDS_GPIO` env var.
- **Three-tier plug/unplug monitor** (so no event is missed on any model):
  1. Primary: a Python monitor listens on the input event device created by `sof_es8336` (`SW_HEADPHONE_INSERT`) + polls the ALSA control every `POLL_INTERVAL` seconds;
  2. Secondary: `alsactl monitor hw:0` (compat channel, may produce no events on some models);
  3. Fallback: pure ALSA polling every 2 seconds.
- **Soft-mute register switch** (`set_amp`):
  - Headphone inserted (`val=0`) → write `0x01=0x00`, muting only the speaker, headphone unaffected;
  - Headphone removed (`val=1`) → raise GPIO power (only when `NEEDS_GPIO=1`) + `reinit_amp()` replays enable registers (`0x01=0x69` and the init sequence), and triggers `unplug_volume_guard` to zero the volume first (no pop).
- **`reinit_amp()` with readback verification and retry**: after writing, it reads back `0x01` to confirm, retrying automatically (up to 3 times; restarting GPIO power when `NEEDS_GPIO=1`).
- **Health-check background loop** (`health_check`, every `HEALTH_CHECK_INTERVAL` seconds, default 60s): checks whether `gpioset` is alive and whether the amplifier `0x01` register holds the expected value (`0x00` when inserted, else `0x69`), auto-recovering on anomaly; also completes volume protection once the PipeWire session becomes ready.

Common env vars (override auto-detection): `GPIOCHIP`, `GPIO_LINE`, `JACK_NUMID`, `I2C_BUS`, `SPK_VOL_NUMID`, `NEEDS_GPIO`, `POLL_INTERVAL`, `HEALTH_CHECK_INTERVAL`.

> Note: an in-kernel alternative was explored earlier (a `JD_INVERTED` quirk for the `es8336` codec driver, in `es8336-jack-invert/`). Because plug/unplug is already reliably observable from user space and the amplifier soft-mute achieves the same result, **the user-space script is the chosen solution** — simpler and instantly reversible, no kernel module build.

## 3. Fix Steps (Deploy)

1. Install the script and systemd service (as root):
   ```bash
   sudo ./install.sh
   ```
   This installs `huawei-speaker-mute.sh` to `/usr/local/bin/` (falls back to `/opt/` if not writable) and enables `huawei-speaker-mute.service` (auto-starts, auto-monitors plug/unplug). On this machine the installed path is `/opt/huawei-speaker-mute.sh`.
   The installer **auto-detects and installs runtime dependencies first**: `i2c-tools` (`i2cset`/`i2cget`), `alsa-utils` (`amixer`/`alsactl`), `libgpiod`/`gpiod` (`gpioset`), `python3` (**required**, used for DSDT parsing and input-event monitoring), `acpica-tools` (`iasl`). `wpctl`/PipeWire is optional — if missing, only the unplug volume guard is skipped; the core mute function is unaffected.

   The repo also ships a `tools/` directory with diagnostic scripts (`jack_watch.py`, `pure_poll.py`, `event_sync_test.py`, `reg_watch.py`); their runtime logs are ignored via `.gitignore`.
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
- A **three-tier monitor** (input event `SW_HEADPHONE_INSERT` + `alsactl monitor` + periodic polling) detects plug/unplug without missing events;
- On transitions, mute/restore the speaker volume through PipeWire (`wpctl`, as the desktop user) to avoid pops;
- DMI detection of whether the BIOS already owns the amplifier GPIO (`NEEDS_GPIO`) distinguishes models that need/don't need user-space GPIO driving;
- A systemd service keeps it resident and starts at boot, with a **health-check background loop** for auto-recovery.

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
