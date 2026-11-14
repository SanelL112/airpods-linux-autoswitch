# airpods-linux-autoswitch

Reliable high-quality 2-way Bluetooth HFP audio (`LC3-24kHz`) and automatic `a2dp-sink` ↔ `headset-head-unit` profile switching on Linux for **AirPods Pro** with **PipeWire / WirePlumber / EasyEffects**.

Tested on Fedora 44 (`kernel 7.2.11`, `pipewire 1.6.9`, `wireplumber 0.5.18`, `bluez 5.87`, `easyeffects 8.2.8`) with an Intel AX201 (`8087:0026`) controller and AirPods Pro 2.

---

## Why this breaks out of the box

Four separate issues stack together when using AirPods Pro on Linux with EasyEffects:

1. **Renamed AirPods skip PipeWire's `bluez-hardware.conf` quirk rule**
   Upstream `/usr/share/spa-0.2/bluez5/bluez-hardware.conf` only matches exact `name = "AirPods Pro"`. Once AirPods are paired from macOS/iOS with a personalized name like `"Alice's AirPods Pro 2nd Generation - Find My"`, the device misses `{ name = "AirPods Pro", no-features = [ msbc-alt1, msbc-alt1-rtl ] }`.
   - `scripts/generate-airpods-quirks.py` reads your installed `/usr/share/spa-0.2/bluez5/bluez-hardware.conf`, adds `{ name = "~AirPods Pro", ... }`, and writes `~/.config/wireplumber/wireplumber.conf.d/50-bluez-airpods.conf` inline via `bluez5.hardware-database` (preventing stale upstream snapshots across PipeWire upgrades).

2. **WirePlumber's autoswitch script stops at EasyEffects (`node.group`)**
   Stock WirePlumber `0.5.18` `autoswitch-bluetooth-profile.lua` traverses `node.link-group` filters, not EasyEffects' input DSP chain (`easyeffects_source -> ee_sie_output_level -> ee_sie_spectrum -> bluez_input.*`, which groups nodes via `node.group = "ee_source_group"`), and ignores intermediate DSP link additions when EasyEffects builds its graph asynchronously.
   - `scripts/patch-wireplumber-autoswitch.py` patches your system `/usr/share/wireplumber/scripts/device/autoswitch-bluetooth-profile.lua` into WirePlumber 0.5's user script override path (`~/.local/share/wireplumber/scripts/device/autoswitch-bluetooth-profile.lua`).

3. **USB autosuspend during HFP SCO/ISOC transitions (`btusb`)**
   Runtime USB suspend on Intel AX201 (`8087:0026`) contributes to `-EMSGSIZE` (`urb ... submission failed (90)`) errors when switching between `a2dp-sink` and `headset-head-unit`.
   - `system/modprobe.d/btusb-autosuspend.conf` (`options btusb enable_autosuspend=0`, takes effect after `btusb` reload/reboot) and `system/udev/99-btusb-nosuspend.rules.in` (forces `power/control=on` immediately).

4. **Spoofed Apple `DeviceID` (`004C:0000:0000`) vs `LC3-24kHz` HFP**
   If `/etc/bluetooth/main.conf` sets `DeviceID = bluetooth:004C:0000:0000` for Apple Handoff, BlueZ exposes `Modalias=bluetooth:v004Cp0000d0000` on D-Bus, causing PipeWire's `bluez5` adapter quirk logic to fall back to generic non-USB adapter matching and destabilizing rapid A2DP ↔ HFP profile switches on Intel USB. Commenting out Apple `DeviceID` trades off Apple Handoff for native Intel USB `LC3-24kHz` stability.

---

## Install

User-only (WirePlumber quirk DB + EasyEffects autoswitch script + save `bluetooth.autoswitch-to-headset-profile = true`):

```bash
./install.sh
```

Include system `btusb` autosuspend rules (`sudo`):

```bash
./install.sh --with-system
```

Also comment out active `DeviceID = bluetooth:004C:...` in `/etc/bluetooth/main.conf` (backs up original to `~/.local/state/airpods-linux-autoswitch/`):

```bash
./install.sh --disable-apple-deviceid
```

Preview without making changes:

```bash
./install.sh --disable-apple-deviceid --dry-run
```

If using a different USB Bluetooth controller, pass `--usb-id VENDOR:PRODUCT` (default `8087:0026`).

---

## Verify

1. Inspect configuration, active codecs (`a2dp-sink` AAC and `headset-head-unit` LC3-24kHz), and USB power control:
   ```bash
   ./scripts/bt-autoswitch-verify.sh
   ```
2. Run a live 3-second playback + capture test (verifies automatic switch to `headset-head-unit`, non-zero microphone samples, and automatic restore to `a2dp-sink`):
   ```bash
   ./scripts/bt-autoswitch-verify.sh --audio-test
   ```

---

## Notes for custom device/preset switchers & browsers

* **Custom PulseAudio/PipeWire scripts:** If you run a custom script or daemon on Bluetooth connect/disconnect, ensure it:
  1. Only initializes `a2dp-sink` when `active_profile` is `"off"` or empty (never force `a2dp-sink` over `headset-head-unit`).
  2. Promotes `bluez_input.*` once on connect rather than pinning `Default Source` to the laptop mic mid-session.
  3. Checks whether `bluez_card.*` still has an active profile before treating a transient sink disappearance during A2DP ↔ HFP switches as a disconnect.
* **Chrome / Electron apps after PipeWire restarts:** If you ever restart `pipewire` / `pipewire-pulse` manually, an already-open Chrome/Chromium browser's `AudioService` keeps a handle to the old socket and shows no microphone/speaker until the tab triggers audio re-enumeration or Chrome restarts (`chrome://restart`). Restarting `wireplumber.service` alone does not require restarting Chrome.

---

## Uninstall

```bash
./install.sh --uninstall            # user overrides only
./install.sh --uninstall --with-system
```

If you used `--disable-apple-deviceid`, restore `DeviceID` from `~/.local/state/airpods-linux-autoswitch/`.
