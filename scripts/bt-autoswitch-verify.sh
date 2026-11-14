#!/usr/bin/env bash
set -euo pipefail

RUN_AUDIO_TEST=0
CARD_FILTER="bluez_card"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audio-test)
      RUN_AUDIO_TEST=1
      shift
      ;;
    --card)
      CARD_FILTER="${2:?missing card filter}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: bt-autoswitch-verify.sh [--audio-test] [--card SUBSTR]

Checks WirePlumber autoswitch state, user overrides, USB power control, BlueZ DeviceID,
and Bluetooth card codec availability. With --audio-test, runs a short 2-way playback
and recording test to verify A2DP -> headset-head-unit -> A2DP switching.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "=== 1. User configuration & overrides ==="
for f in \
  "$HOME/.config/wireplumber/wireplumber.conf.d/50-bluez-airpods.conf" \
  "$HOME/.local/share/wireplumber/scripts/device/autoswitch-bluetooth-profile.lua"
do
  if [[ -f "$f" ]]; then
    echo "[ok] $f"
  else
    echo "[missing] $f"
  fi
done

if command -v wpctl >/dev/null 2>&1; then
  wpctl settings | grep -A 5 'bluetooth\.autoswitch-to-headset-profile' || true
fi

echo "=== 2. System configuration ==="
if [[ -f /etc/bluetooth/main.conf ]]; then
  grep -n 'DeviceID' /etc/bluetooth/main.conf || echo "[info] No DeviceID entry in /etc/bluetooth/main.conf"
fi
if [[ -f /etc/modprobe.d/btusb-autosuspend.conf ]]; then
  echo "[ok] /etc/modprobe.d/btusb-autosuspend.conf: $(tr '\n' ' ' </etc/modprobe.d/btusb-autosuspend.conf)"
else
  echo "[warn] /etc/modprobe.d/btusb-autosuspend.conf not installed"
fi
if [[ -f /etc/udev/rules.d/99-btusb-nosuspend.rules ]]; then
  echo "[ok] /etc/udev/rules.d/99-btusb-nosuspend.rules present"
else
  echo "[warn] /etc/udev/rules.d/99-btusb-nosuspend.rules not installed"
fi

for ctrl in /sys/bus/usb/devices/*/power/control; do
  dev_dir="$(dirname "$(dirname "$ctrl")")"
  if [[ -f "$dev_dir/idVendor" ]] && [[ "$(cat "$dev_dir/idVendor"):$(cat "$dev_dir/idProduct")" == "8087:0026" ]]; then
    echo "[ok] USB 8087:0026 ($dev_dir) power/control=$(cat "$ctrl")"
  fi
done
if [[ -r /sys/module/btusb/parameters/enable_autosuspend ]]; then
  echo "[info] btusb enable_autosuspend=$(cat /sys/module/btusb/parameters/enable_autosuspend)"
fi

echo "=== 3. Active Bluetooth card & profiles ==="
pactl info | grep -E 'Server Name|Default (Sink|Source)'
if pactl list cards | grep -q "Name: ${CARD_FILTER}"; then
  pactl list cards | awk "/Name: ${CARD_FILTER}/,/Ports:/" | grep -E 'Name:|device\.description|Active Profile:|a2dp-sink|headset-head-unit'
else
  echo "[warn] No matching Bluetooth card found for '${CARD_FILTER}'"
  exit 0
fi

if [[ "$RUN_AUDIO_TEST" -eq 0 ]]; then
  exit 0
fi

echo "=== 4. Live 2-way autoswitch test ==="
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$TMP_DIR/tone.wav" <<'PY'
import math, struct, sys, wave
sr, dur, freq, amp = 48000, 3.5, 440.0, 0.04
with wave.open(sys.argv[1], "w") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    frames = bytearray()
    for i in range(int(sr * dur)):
        v = int(32767 * amp * math.sin(2 * math.pi * freq * i / sr))
        frames += struct.pack("<hh", v, v)
    w.writeframes(frames)
PY

TARGET_REC=""
if pactl list short sources | awk '{print $2}' | grep -qx 'easyeffects_source'; then
  TARGET_REC="--target=easyeffects_source"
  echo "[info] Capturing via easyeffects_source"
fi

timeout 3.0 pw-play "$TMP_DIR/tone.wav" >/dev/null 2>&1 &
P_PLAY=$!
# shellcheck disable=SC2086
timeout 3.0 pw-record $TARGET_REC --rate=48000 --channels=1 "$TMP_DIR/rec.wav" >/dev/null 2>&1 &
P_REC=$!

sleep 1.8
PROF_DURING="$(pactl list cards | awk "/Name: ${CARD_FILTER}/,0" | awk -F': ' '/Active Profile:/{print $2; exit}')"
wait "$P_PLAY" "$P_REC" || true
sleep 3.5
PROF_AFTER="$(pactl list cards | awk "/Name: ${CARD_FILTER}/,0" | awk -F': ' '/Active Profile:/{print $2; exit}')"

python3 - "$PROF_DURING" "$PROF_AFTER" "$TMP_DIR/rec.wav" <<'PY'
import math, struct, sys, wave
during, after, path = sys.argv[1:4]
with wave.open(path, "rb") as w:
    raw = w.readframes(w.getnframes())
samples = struct.unpack("<" + "h" * (len(raw) // 2), raw) if raw else ()
nz = sum(1 for s in samples if s != 0)
rms = math.sqrt(sum(s * s for s in samples) / len(samples)) if samples else 0.0
peak = max((abs(s) for s in samples), default=0)
print(f"during={during} after={after} samples={len(samples)} nz={nz} rms={rms:.2f} peak={peak}")
if during != "headset-head-unit" or after != "a2dp-sink" or nz == 0:
    raise SystemExit(1)
PY
echo "[ok] Live 2-way autoswitch verified"
