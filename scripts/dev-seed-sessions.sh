#!/usr/bin/env bash
# Usage: CMUX_TAG=<tag> scripts/dev-seed-sessions.sh [count=5]
# why: opens the DEV build populated with `claude --resume` tabs; never picks
# a session live elsewhere or active in the real build (double-resume unsafe).
# The last two picks share one workspace as two terminal tabs (multi-tab mock).
set -euo pipefail

if [[ -z "${CMUX_TAG:-}" ]]; then
  echo "CMUX_TAG is required (same tag as the running DEV build)." >&2
  exit 2
fi

COUNT="${1:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOCK="/tmp/cmux-debug-${CMUX_TAG}.sock"
for _ in $(seq 1 40); do
  [[ -S "$SOCK" ]] && break
  sleep 0.5
done
if [[ ! -S "$SOCK" ]]; then
  echo "DEV socket $SOCK never appeared; is the tagged app running?" >&2
  exit 1
fi

SIDS=()
CWDS=()
while IFS=$'\t' read -r sid cwd; do
  SIDS+=("$sid")
  CWDS+=("$cwd")
done < <(python3 - "$COUNT" <<'PYEOF'
import glob, json, os, random, sys

count = int(sys.argv[1])
home = os.path.expanduser("~")

# ponytail: "in use by the real build" = live sidecar OR active hook-store binding
exclude = set()
for f in glob.glob(f"{home}/.claude/sessions/*.json"):
    try:
        exclude.add(json.load(open(f)).get("sessionId"))
    except Exception:
        pass
try:
    store = json.load(open(f"{home}/.cmuxterm/claude-hook-sessions.json"))
    for entry in (store.get("activeSessionsBySurface") or {}).values():
        if isinstance(entry, dict):
            exclude.add(entry.get("sessionId"))
except Exception:
    pass

candidates = []
for f in glob.glob(f"{home}/.claude/projects/*/*.jsonl"):
    sid = os.path.basename(f)[:-6]
    if sid in exclude:
        continue
    try:
        if os.path.getsize(f) < 20_000:  # skip near-empty sessions
            continue
    except OSError:
        continue
    cwd = None
    with open(f) as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            if entry.get("cwd"):
                cwd = entry["cwd"]
                break
    if cwd and os.path.isdir(cwd):
        candidates.append((sid, cwd))

random.shuffle(candidates)
seen_ids = set()
picked = []
for sid, cwd in candidates:
    if sid in seen_ids:
        continue
    seen_ids.add(sid)
    picked.append((sid, cwd))
    if len(picked) == count:
        break

for sid, cwd in picked:
    print(f"{sid}\t{cwd}")
PYEOF
)

TOTAL=${#SIDS[@]}
if (( TOTAL == 0 )); then
  echo "no seedable sessions found (all live, active in the real build, or too small)" >&2
  exit 0
fi

SINGLES=$TOTAL
if (( TOTAL >= 3 )); then
  SINGLES=$((TOTAL - 2))
fi

for ((i = 0; i < SINGLES; i++)); do
  CMUX_QUIET=1 "$SCRIPT_DIR/cmux-debug-cli.sh" workspace create \
    --cwd "${CWDS[$i]}" \
    --command "claude --resume ${SIDS[$i]}"
  echo "seeded: ${SIDS[$i]} (${CWDS[$i]})"
done

if (( TOTAL >= 3 )); then
  A=$((TOTAL - 2)); B=$((TOTAL - 1))
  LAYOUT=$(python3 -c '
import json, sys
print(json.dumps({"pane": {"surfaces": [
    {"type": "terminal", "cwd": sys.argv[2], "command": "claude --resume " + sys.argv[1]},
    {"type": "terminal", "cwd": sys.argv[4], "command": "claude --resume " + sys.argv[3]},
]}}))' "${SIDS[$A]}" "${CWDS[$A]}" "${SIDS[$B]}" "${CWDS[$B]}")
  CMUX_QUIET=1 "$SCRIPT_DIR/cmux-debug-cli.sh" workspace create \
    --cwd "${CWDS[$A]}" \
    --layout "$LAYOUT"
  echo "seeded multi-tab: ${SIDS[$A]} + ${SIDS[$B]} (${CWDS[$A]})"
fi
