#!/usr/bin/env bash
# Takes the store screenshots in a simulator.
#
#   scripts/store_screenshots.sh <simulator-udid> <folder-name>
#
# Runs integration_test/store_screenshots_test.dart, which prints
# "STORE_SHOT <name>" on each screen and holds it for a few seconds; this
# script answers each with `simctl io screenshot`, so the image is exactly what
# the simulator shows, status bar included.
set -euo pipefail

sim="${1:?simulator udid}"
name="${2:?output folder name, e.g. ipad}"
out="build/store_screenshots/$name"
log="build/store_screenshots/$name.log"

mkdir -p "$out"
: > "$log"

xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl status_bar "$sim" override --time "9:41" \
  --batteryState charged --batteryLevel 100 --wifiBars 3 \
  --cellularMode notSupported

flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/store_screenshots_test.dart \
  -d "$sim" --dart-define=STORE_SCREENSHOTS=true >"$log" 2>&1 &
drive=$!

# Poll the log rather than `tail -f`, which outlives the run.
taken=""
while kill -0 "$drive" 2>/dev/null; do
  for shot in $(sed -n 's/.*STORE_SHOT \([A-Za-z0-9_]*\).*/\1/p' "$log"); do
    case " $taken " in *" $shot "*) continue ;; esac
    sleep 1
    xcrun simctl io "$sim" screenshot --type=png "$out/$shot.png" >/dev/null 2>&1
    taken="$taken $shot"
    echo "took $shot"
  done
  sleep 0.5
done
grep -E "All tests passed|Some tests failed" "$log" | tail -1

wait "$drive" || { echo "flutter drive failed; see $log"; exit 1; }
