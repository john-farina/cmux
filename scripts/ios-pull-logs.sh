#!/usr/bin/env bash
# fork: pull the iPhone dev build's debug log files off the device (works over
# wifi via the coredevice tunnel — no cable needed, unlike `log collect`).
set -euo pipefail

BUNDLE_ID="${CMUX_IOS_BUNDLE_ID:-dev.cmux.ios.john}"
DEVICE="${CMUX_IOS_DEVICE:-00008130-001828D1023A001C}"
DEST="${1:-/tmp/cmux-iphone-logs}"
mkdir -p "$DEST"

for f in cmux-debug.log cmux-auth-debug.log; do
  if xcrun devicectl device copy from \
      --device "$DEVICE" \
      --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" \
      --source "Documents/$f" \
      --destination "$DEST/$f" 2>/dev/null; then
    echo "pulled $DEST/$f ($(wc -l < "$DEST/$f" | tr -d ' ') lines)"
  else
    echo "no $f on device (feature not exercised yet, or app not installed)"
  fi
done
