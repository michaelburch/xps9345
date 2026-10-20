#!/bin/bash
# Capture a PM-state snapshot for diffing across kernel versions.
# Run on battery, idle desktop, same userspace state for each kernel.
#
# Usage: sudo ./xps-pm-snapshot.sh [tag]
#   tag is an optional label appended to the filename (e.g. "battery-idle")

set -u

if [[ $EUID -ne 0 ]]; then
	echo "must run as root (debugfs needs it)" >&2
	exit 1
fi

TAG="${1:-snapshot}"
KREL="$(uname -r)"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$(pwd)/logs}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/pm-${KREL}-${TAG}-${TS}.log"

section() { printf '\n\n===== %s =====\n' "$1" >> "$OUT"; }
dump()    { echo "--- $1 ---" >> "$OUT"; cat "$1" 2>>"$OUT" >> "$OUT" || true; }
run()     { echo "--- \$ $* ---" >> "$OUT"; "$@" >> "$OUT" 2>&1 || true; }

# Battery power draw (W). POWER_NOW is in microwatts; negative means discharging.
PNOW_UW=""
for bat in /sys/class/power_supply/*/power_now; do
	[[ -r "$bat" ]] || continue
	v=$(cat "$bat" 2>/dev/null) || continue
	[[ -n "$v" && "$v" != "0" ]] || continue
	PNOW_UW="$v"
	break
done
if [[ -n "$PNOW_UW" ]]; then
	# abs(uW) -> W with 2 decimals
	PNOW_W=$(awk -v v="$PNOW_UW" 'BEGIN{ if (v<0) v=-v; printf "%.2f", v/1000000 }')
else
	PNOW_W="?"
fi

{
	echo "kernel:    $KREL"
	echo "host:      $(hostname)"
	echo "date:      $(date -Is)"
	echo "uptime:    $(uptime -p)"
	echo "tag:       $TAG"
	echo "cmdline:   $(cat /proc/cmdline)"
	echo "power_now: ${PNOW_W} W (${PNOW_UW} uW)"
} > "$OUT"

echo "power_now: ${PNOW_W} W  [${KREL} ${TAG}]"

section "uname / version"
run uname -a
dump /proc/version

section "power supply (battery draw)"
for ps in /sys/class/power_supply/*; do
	[[ -d "$ps" ]] || continue
	dump "$ps/uevent"
done

section "pm_genpd_summary"
dump /sys/kernel/debug/pm_genpd/pm_genpd_summary

section "regulators"
for r in /sys/class/regulator/*/; do
	name=$(cat "$r/name" 2>/dev/null) || continue
	state=$(cat "$r/state" 2>/dev/null || echo ?)
	uv=$(cat "$r/microvolts" 2>/dev/null || echo ?)
	users=$(cat "$r/num_users" 2>/dev/null || echo ?)
	printf '%-32s state=%-10s uV=%-10s users=%s\n' "$name" "$state" "$uv" "$users" >> "$OUT"
done

section "cpuidle residency"
for c in /sys/devices/system/cpu/cpu*/cpuidle; do
	[[ -d "$c" ]] || continue
	cpu=$(echo "$c" | sed 's:.*/cpu\([0-9]*\)/.*:\1:')
	for s in "$c"/state*; do
		name=$(cat "$s/name" 2>/dev/null)
		usage=$(cat "$s/usage" 2>/dev/null)
		time=$(cat "$s/time" 2>/dev/null)
		printf 'cpu%-2s %-12s usage=%-10s time_us=%s\n' "$cpu" "$name" "$usage" "$time" >> "$OUT"
	done
done

section "cpufreq time_in_state"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[[ -d "$p" ]] || continue
	echo "--- $p ---" >> "$OUT"
	dump "$p/stats/time_in_state"
done

section "OPP tables"
if [[ -d /sys/kernel/debug/opp ]]; then
	for d in /sys/kernel/debug/opp/*/; do
		echo "--- $d ---" >> "$OUT"
		find "$d" -type f \( -name 'rate_hz' -o -name 'available' -o -name 'level' \) \
			-print -exec cat {} \; >> "$OUT" 2>&1 || true
	done
fi

section "clk_summary (active clocks)"
dump /sys/kernel/debug/clk/clk_summary

section "wakeup sources"
dump /sys/kernel/debug/wakeup_sources

section "loaded modules"
run lsmod

section "PM tunables"
run cat /sys/power/mem_sleep
run cat /sys/power/state
run cat /sys/module/printk/parameters/console_suspend 2>/dev/null

section "tuned active profile"
run tuned-adm active

echo
echo "wrote $OUT"
