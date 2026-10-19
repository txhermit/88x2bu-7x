#!/bin/sh
#
# tests/injection-benchmark.sh — repeatable injection benchmark harness.
#
# Implements TESTING.md sections 1-2 plus the dmesg/env snapshot discipline.
#
# Usage:
#   sudo ./tests/injection-benchmark.sh <wlan-iface> <target-bssid> <channel>
#
# Example:
#   sudo ./tests/injection-benchmark.sh wlan1 AA:BB:CC:DD:EE:FF 36
#
# Requirements: aircrack-ng suite, iw, ip. The target AP must be YOUR OWN
# test AP. NetworkManager/wpa_supplicant must be stopped first.
#
# Results land in results/<driver-commit>/<kernel>/<timestamp>/ as CSVs,
# dmesg snapshots, env.txt and summary.txt.
#
# NOTE: hardware-dependent; needs the adapter on a real 7.x box. Not yet
# run end-to-end — treat as a v0 harness, tighten after the first session.

set -u

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

if [ "$#" -ne 3 ]; then
	echo "Usage: $0 <wlan-iface> <target-bssid> <channel>" >&2
	exit 1
fi

WLAN="$1"
BSSID="$2"
CHAN="$3"
MON="${WLAN}mon"
RUNS=5
FRAMES=1000

for cmd in aireplay-ng iw ip dmesg git modinfo; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "Missing required tool: $cmd" >&2; exit 1
	}
done

COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
KVER=$(uname -r)
STAMP=$(date +%Y-%m-%d-%H%M)
OUT="results/${COMMIT}/${KVER}/${STAMP}"
mkdir -p "$OUT"

echo "== 88x2bu-7x injection benchmark =="
echo "driver commit: $COMMIT  kernel: $KVER  target: $BSSID ch $CHAN"
echo "results: $OUT"

# --- environment snapshot ----------------------------------------------------
{
	echo "date: $(date -u +%FT%TZ)"
	echo "commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
	echo "kernel: $KVER"
	echo "gcc: $(gcc --version 2>/dev/null | head -1)"
	echo "--- lsusb (adapter) ---"
	lsusb | grep -i -E 'realtek|0bda' || true
	echo "--- iw reg get ---"
	iw reg get
	echo "--- module params ---"
	grep -H . /sys/module/88x2bu/parameters/* 2>/dev/null || true
	echo "--- modinfo ---"
	modinfo 88x2bu 2>/dev/null | grep -E '^(version|filename|vermagic)' || true
} > "${OUT}/env.txt"
dmesg > "${OUT}/dmesg-before.log"

# --- bring up monitor interface ----------------------------------------------
ip link set "$WLAN" down
iw dev "$WLAN" set type monitor
ip link set "$WLAN" up
# rename to a stable mon name if the driver didn't create one
if ! ip link show "$MON" >/dev/null 2>&1; then
	ip link set "$WLAN" name "$MON"
fi
iw dev "$MON" set channel "$CHAN"
iw dev "$MON" set txpower fixed 2000   # 20 dBm; adjust to your reg domain
rfkill unblock wifi 2>/dev/null || true

# --- test 1: aireplay-ng smoke -------------------------------------------------
echo "-- aireplay-ng --test (smoke) --"
aireplay-ng --test "$MON" 2>&1 | tee "${OUT}/aireplay-test.log" | tail -5

# --- test 2: sustained injection, N runs ---------------------------------------
echo "run,tx_attempted,tx_ok,success_pct" > "${OUT}/runs.csv"
i=1
while [ "$i" -le "$RUNS" ]; do
	echo "-- run $i/$RUNS: injecting $FRAMES frames --"
	# recreate the monitor interface between runs to reset driver state
	ip link set "$MON" down
	iw dev "$MON" set type monitor
	ip link set "$MON" up
	iw dev "$MON" set channel "$CHAN"

	LOG="${OUT}/run-${i}.log"
	# -9 injection test mode, quiet-ish; parse the success line
	aireplay-ng -9 -a "$BSSID" -i "$MON" "$MON" > "$LOG" 2>&1 &
	PID=$!
	sleep 2
	# feed it: aireplay -9 runs its own count; wait for completion
	wait "$PID" || true

	# aireplay-ng -9 prints e.g. "xx/30: 100%" style lines; fall back to
	# counting ACKs if the format differs on your aircrack version.
	PCT=$(grep -oE '[0-9]{1,3}%' "$LOG" | tail -1 | tr -d '%' || echo "")
	if [ -z "$PCT" ]; then PCT="NA"; fi
	echo "${i},${FRAMES},NA,${PCT}" >> "${OUT}/runs.csv"
	i=$((i + 1))
	sleep 3
done

dmesg > "${OUT}/dmesg-after.log"

# --- summary --------------------------------------------------------------------
{
	echo "driver commit: $COMMIT"
	echo "kernel: $KVER"
	echo "target: $BSSID channel $CHAN, $RUNS runs x $FRAMES frames"
	echo ""
	echo "per-run success %:"
	cut -d, -f4 "${OUT}/runs.csv" | tail -n +2
	echo ""
	echo "dmesg warnings/errors during benchmark:"
	dmesg | grep -iE 'warn|error|oops|disconnect' | grep -i -E '88x2bu|usb|rtw|cfg80211' | tail -20 || echo "(none)"
} > "${OUT}/summary.txt"

cat "${OUT}/summary.txt"
echo
echo "Done. Review ${OUT}/summary.txt and commit env.txt + summary.txt with the release notes."
