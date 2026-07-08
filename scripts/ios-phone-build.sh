#!/usr/bin/env bash
# fork: build + install the cmux iOS companion (prod auth) to the paired iPhone.
# why: encapsulates the known-good invocation — Xcode 26.6 toolchain (Xcode21's
# swift is too old for upstream mobile packages) and the Triumph dev team.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IOS_DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-9QFLC277YH}"

DEVICE_ID="${CMUX_IOS_DEVICE:-00008130-001828D1023A001C}" # John's iPhone; fleet devices also stay paired
exec ios/scripts/reload.sh --tag john --device-only --prod-auth --allow-device-registration --device-id "$DEVICE_ID" "$@"
