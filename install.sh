#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_SYSTEM=0
DISABLE_APPLE_DEVICEID=0
UNINSTALL=0
DRY_RUN=0
USB_ID="8087:0026"

QUIRKS_OUT="$HOME/.config/wireplumber/wireplumber.conf.d/50-bluez-airpods.conf"
LUA_OUT="$HOME/.local/share/wireplumber/scripts/device/autoswitch-bluetooth-profile.lua"
MODPROBE_DST="/etc/modprobe.d/btusb-autosuspend.conf"
UDEV_DST="/etc/udev/rules.d/99-btusb-nosuspend.rules"
BLUEZ_CONF="/etc/bluetooth/main.conf"

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Installs WirePlumber overrides for AirPods Pro quirk matching and EasyEffects
node.group autoswitching, plus optional system-wide BlueZ/btusb fixes.

Options:
  --with-system            Install /etc/modprobe.d and udev USB autosuspend rules (uses sudo)
  --disable-apple-deviceid Comment out Apple DeviceID = bluetooth:004C:... in /etc/bluetooth/main.conf
                           (trades Apple Handoff for LC3-24kHz stability; implies --with-system)
  --usb-id VENDOR:PRODUCT  USB adapter ID for udev rule (default: 8087:0026 Intel AX201)
  --uninstall              Remove user overrides (and system rules if --with-system is set)
  --dry-run                Print actions without modifying any files or restarting services
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-system)
      WITH_SYSTEM=1
      shift
      ;;
    --disable-apple-deviceid)
      WITH_SYSTEM=1
      DISABLE_APPLE_DEVICEID=1
      shift
      ;;
    --usb-id)
      USB_ID="${2:?missing VENDOR:PRODUCT}"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$USB_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
  echo "error: --usb-id must look like VENDOR:PRODUCT (4 hex digits each), got '$USB_ID'" >&2
  exit 1
fi
VENDOR_ID="${USB_ID%%:*}"
PRODUCT_ID="${USB_ID##*:}"

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  for f in "$QUIRKS_OUT" "$LUA_OUT"; do
    if [[ -e "$f" ]]; then
      run_cmd rm -f "$f"
      echo "Removed $f"
    fi
  done
  if [[ "$WITH_SYSTEM" -eq 1 ]]; then
    run_cmd sudo rm -f "$MODPROBE_DST" "$UDEV_DST"
    run_cmd sudo udevadm control --reload-rules
    echo "Removed $MODPROBE_DST and $UDEV_DST"
    echo "Note: if you disabled DeviceID in $BLUEZ_CONF, restore it manually if desired."
  fi
  run_cmd systemctl --user restart wireplumber.service
  exit 0
fi

echo "=== Installing user WirePlumber overrides ==="
if [[ "$DRY_RUN" -eq 1 ]]; then
  python3 "$ROOT_DIR/scripts/generate-airpods-quirks.py" --dry-run --output "$QUIRKS_OUT"
  python3 "$ROOT_DIR/scripts/patch-wireplumber-autoswitch.py" --dry-run --output "$LUA_OUT"
  echo "[dry-run] wpctl settings --save bluetooth.autoswitch-to-headset-profile true"
else
  python3 "$ROOT_DIR/scripts/generate-airpods-quirks.py" --output "$QUIRKS_OUT"
  python3 "$ROOT_DIR/scripts/patch-wireplumber-autoswitch.py" --output "$LUA_OUT"
  wpctl settings --save bluetooth.autoswitch-to-headset-profile true
fi

if [[ "$WITH_SYSTEM" -eq 1 ]]; then
  echo "=== Installing btusb autosuspend prevention (${VENDOR_ID}:${PRODUCT_ID}) ==="
  TMP_RULE="$(mktemp)"
  trap 'rm -f "$TMP_RULE"' EXIT
  sed -e "s/@VENDOR_ID@/${VENDOR_ID}/g" -e "s/@PRODUCT_ID@/${PRODUCT_ID}/g" \
    "$ROOT_DIR/system/udev/99-btusb-nosuspend.rules.in" > "$TMP_RULE"

  run_cmd sudo install -Dm644 "$ROOT_DIR/system/modprobe.d/btusb-autosuspend.conf" "$MODPROBE_DST"
  run_cmd sudo install -Dm644 "$TMP_RULE" "$UDEV_DST"
  run_cmd sudo udevadm control --reload-rules
  run_cmd sudo udevadm trigger --subsystem-match=usb --attr-match="idVendor=${VENDOR_ID}" --attr-match="idProduct=${PRODUCT_ID}"

  if [[ "$DISABLE_APPLE_DEVICEID" -eq 1 ]] && [[ -f "$BLUEZ_CONF" ]]; then
    if grep -qE '^[[:space:]]*DeviceID[[:space:]]*=[[:space:]]*bluetooth:004C:' "$BLUEZ_CONF"; then
      echo "=== Disabling Apple DeviceID in $BLUEZ_CONF ==="
      BACKUP_DIR="$HOME/.local/state/airpods-linux-autoswitch"
      run_cmd mkdir -p "$BACKUP_DIR"
      run_cmd cp "$BLUEZ_CONF" "$BACKUP_DIR/main.conf.bak.$(date +%Y%m%d-%H%M%S)"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] Comment out Apple DeviceID in $BLUEZ_CONF and restart bluetooth.service"
      else
        sudo python3 - "$BLUEZ_CONF" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
updated, n = re.subn(
    r'^([ \t]*DeviceID\s*=\s*bluetooth:004C:[^\n]*)',
    r'# Disabled for Linux HFP LC3-24kHz stability (re-enable for Apple Handoff)\n#\1',
    text,
    flags=re.MULTILINE,
)
if n:
    with open(path, "w", encoding="utf-8") as f:
        f.write(updated)
PY
        sudo systemctl restart bluetooth.service
      fi
    else
      echo "[info] No active Apple DeviceID found in $BLUEZ_CONF"
    fi
  fi
fi

echo "=== Restarting WirePlumber ==="
run_cmd systemctl --user restart wireplumber.service
echo "Done. Reconnect your AirPods and run: ./scripts/bt-autoswitch-verify.sh"
