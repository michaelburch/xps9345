#!/bin/bash
# Capture Qualcomm sleep-stat deltas across a manual suspend cycle.
#
# Reads /sys/kernel/debug/qcom_stats/{apss,adsp,cdsp,modem,slpi,gpu,...}
# before suspend and after resume, computes the delta in count and
# accumulated duration, and reports residency % of wall time.
#
# Usage: sudo ./xps-rpmh-stats.sh [TAG] [-s SUSPEND_SECS] [--usb-wakeup-off] [--stats-only] [--no-freqsync]
#   TAG: free-form label for the output log (default: rpmh)
#   SUSPEND_SECS: target seconds in suspend; waking earlier is reported, not waited out (default: 600)
#
# The pm8xxx RTC has no wakeup, so suspend is always manual:
# the script suspends with `systemctl suspend --no-block` and detects
# resume via a CLOCK_BOOTTIME-vs-MONOTONIC jump. Wake the laptop with
# the power button after the requested interval.
# XO/TCSR validation uses a private trace instance and temporary RPMh cache
# debug prints. Setup failure aborts before suspend. PLD is managed separately.
# --usb-wakeup-off temporarily disables wakeup on the three USB controllers.
# USB devices cannot wake this test; use the power button. Prior settings are restored.
# --stats-only skips tracing/debug prints and refuses existing active instrumentation.
# --no-freqsync skips the pre-suspend ddr_stats read; every read sends the AOP
# {class: ddr, action: freqsync}. DDR LPM is then reported since boot.

set -u

if [[ $EUID -ne 0 ]]; then
	echo "must run as root (debugfs needs it)" >&2
	exit 1
fi

STATS_DIR=/sys/kernel/debug/qcom_stats
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/xps-rpmh-xo.sh"
XO_CLK_DIR=/sys/kernel/debug/clk
XO_SUSPEND_DIR=/sys/power/suspend_stats
XO_TRACE_ROOT=/sys/kernel/tracing
XO_DYNDBG=/sys/kernel/debug/dynamic_debug/control
XO_CMD_DB=/sys/kernel/debug/cmd-db
XO_LOCK_FILE=/run/lock/xps-rpmh-stats.lock
if [[ ! -d "$STATS_DIR" ]]; then
	echo "missing $STATS_DIR — qcom_stats debugfs not present" >&2
	exit 1
fi

TAG="rpmh"
SUSPEND_SECS=600
USB_WAKEUP_OFF=0
XO_STATS_ONLY=0
NO_FREQSYNC=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		-s) SUSPEND_SECS="$2"; shift 2 ;;
		--usb-wakeup-off) USB_WAKEUP_OFF=1; shift ;;
		--stats-only) XO_STATS_ONLY=1; shift ;;
		--no-freqsync) NO_FREQSYNC=1; shift ;;
		-h|--help)
			sed -n '2,22p' "$0"; exit 0 ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) TAG="$1"; shift ;;
	esac
done

KREL="$(uname -r)"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$(cd "$(dirname "$0")/.." && pwd)/logs}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/rpmh-${KREL}-${TAG}-${TS}-$$.log"
XO_TRACE_OUT="${OUT%.log}.xo.trace"
XO_TRACE_STATS="${OUT%.log}.xo.trace-stats"
XO_KERNEL_OUT="${OUT%.log}.xo.kernel.log"

# Subsystems we care about. Files that are empty are silently skipped.
SUBS=(apss adsp adsp_island cdsp cdsp1 modem slpi slpi_island wpss gpu display aosd cxsd ddr)

# qcom_stats accumulates arch-timer ticks, not nanoseconds.
TICK_HZ="$(awk '/cp15 timer.*running at/ {
		if (match($0, /running at [0-9.]+MHz/)) {
			s = substr($0, RSTART + 11, RLENGTH - 15)
			printf "%.0f", s * 1000000
			exit
		}
	}' < <(journalctl -kb 2>/dev/null))"
: "${TICK_HZ:=19200000}"

# Read CLOCK_BOOTTIME (counts suspend) and CLOCK_MONOTONIC (does not).
# A jump of (boottime - monotonic) reveals time spent suspended.
read_boottime_ns() { awk '/^now at/ {print $3}' /proc/timer_list 2>/dev/null | head -1; }
now_mono_s()       { awk 'BEGIN{ "date +%s.%N" | getline t; print t }'; }
now_boot_s()       { python3 -c 'import time; print(time.clock_gettime(time.CLOCK_BOOTTIME))' 2>/dev/null \
                     || awk '/btime/{print $2}' /proc/stat; }
now_mono_only_s()  { python3 -c 'import time; print(time.clock_gettime(time.CLOCK_MONOTONIC))' 2>/dev/null \
                     || cat /proc/uptime | awk '{print $1}'; }

# snapshot <prefix>: write each non-empty subsystem stat file as
#   PREFIX_<sub>_count, PREFIX_<sub>_dur (ns)
declare -A SNAP
snapshot() {
	local prefix="$1" sub f content count entered exited dur
	for sub in "${SUBS[@]}"; do
		f="$STATS_DIR/$sub"
		[[ -r "$f" ]] || continue
		# debugfs files report size 0 even when populated; we must read.
		content=$(cat "$f" 2>/dev/null)
		if [[ -z "$content" ]]; then
			SNAP["${prefix}_${sub}_present"]=0
			continue
		fi
		count=$(awk -F: '/^Count/{gsub(/ /,"",$2); print $2; exit}' <<<"$content")
		entered=$(awk -F: '/^Last Entered At/{gsub(/ /,"",$2); print $2; exit}' <<<"$content")
		exited=$(awk -F: '/^Last Exited At/{gsub(/ /,"",$2); print $2; exit}' <<<"$content")
		dur=$(awk -F: '/^Accumulated Duration/{gsub(/ /,"",$2); print $2; exit}' <<<"$content")
		SNAP["${prefix}_${sub}_present"]=1
		SNAP["${prefix}_${sub}_count"]="${count:-0}"
		SNAP["${prefix}_${sub}_entered"]="${entered:-0}"
		SNAP["${prefix}_${sub}_exited"]="${exited:-0}"
		SNAP["${prefix}_${sub}_dur"]="${dur:-0}"
	done
}

read_ddr_stats() {
	local f="$STATS_DIR/ddr_stats"
	[[ -r "$f" ]] && cat "$f" || true
}

# Summed residency ticks of the DDR low-power states 0xd4/0xd3/0x11.
ddr_lpm_ticks() {
	awk '/Name:0x(d4|d3|11)[[:space:]]/ && match($0, /\(ticks\):[0-9]+/) {
		s += substr($0, RSTART + 8, RLENGTH - 8) } END { printf "%.0f", s }' <<<"$1"
}

read_wakeup_sources() {
	local f=/sys/kernel/debug/wakeup_sources
	[[ -r "$f" ]] && cat "$f" || true
}

# CPU PM-domain idle states, one line per state:
#   <domain> <state> <time_ms> <usage> <rejected> <above> <below> <s2idle>
# "rejected" counts PSCI CPU_SUSPEND calls that returned without powering down.
read_genpd_cpu_domains() {
	local d
	for d in /sys/kernel/debug/pm_genpd/power-domain-system \
		 /sys/kernel/debug/pm_genpd/power-domain-cpu-cluster*; do
		[[ -r "$d/idle_states" ]] || continue
		awk -v pd="${d##*/}" 'NR > 1 { print pd, $0 }' "$d/idle_states"
	done
}

# Per-CPU cpuidle states: <cpu> <state> <usage> <rejected> <s2idle_usage>
read_cpuidle_states() {
	local s cpu
	for s in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[0-9]*; do
		[[ -r "$s/usage" ]] || continue
		cpu=${s%/cpuidle/*}
		printf '%s %s %s %s %s\n' "${cpu##*/}" "${s##*/}" \
			"$(cat "$s/usage")" "$(cat "$s/rejected")" \
			"$(cat "$s/s2idle/usage" 2>/dev/null || echo 0)"
	done
}

# Current aggregate of a PM QoS char device, in us.
read_qos_us() {
	[[ -e "$1" ]] || { echo "n/a"; return; }
	python3 -c 'import os,struct,sys; fd=os.open(sys.argv[1], os.O_RDONLY); print(struct.unpack("i", os.read(fd, 4))[0])' "$1" 2>/dev/null || echo "?"
}

# print_counter_deltas <pre> <post> <columns>: lines are "<key1> <key2> <n>...";
# prints keys whose listed columns changed.
print_counter_deltas() {
	awk -v pre="$1" -v post="$2" -v cols="$3" '
	BEGIN {
		ncol = split(cols, col, " ")
		n = split(pre, lines, "\n")
		for (i = 1; i <= n; i++) {
			if (split(lines[i], f, " ") < 3)
				continue
			for (c = 1; c <= ncol; c++)
				old[f[1] " " f[2], c] = f[col[c]]
		}
		n = split(post, lines, "\n")
		for (i = 1; i <= n; i++) {
			if (split(lines[i], f, " ") < 3)
				continue
			out = sprintf("%-26s %-7s", f[1], f[2])
			changed = 0
			for (c = 1; c <= ncol; c++) {
				d = f[col[c]] - old[f[1] " " f[2], c]
				if (d)
					changed = 1
				out = out sprintf(" %10d", d)
			}
			if (changed)
				print out
		}
	}'
}

print_wakeup_deltas() {
	local pre="$1" post="$2"

	printf '%-44s %10s %10s %10s %12s\n' \
		"source" "dActive" "dEvent" "dWakeup" "dTime(ms)"
	awk -v pre="$pre" -v post="$post" '
	function parse(text, which, lines, fields, count, i, name) {
		count = split(text, lines, "\n")
		for (i = 2; i <= count; i++) {
			split(lines[i], fields, /[[:space:]]+/)
			name = fields[1]
			if (!name)
				continue
			if (which == "pre") {
				pre_active[name] = fields[2]
				pre_event[name] = fields[3]
				pre_wakeup[name] = fields[4]
				pre_time[name] = fields[7]
			} else {
				post_active[name] = fields[2]
				post_event[name] = fields[3]
				post_wakeup[name] = fields[4]
				post_time[name] = fields[7]
				names[name] = 1
			}
		}
	}
	BEGIN {
		parse(pre, "pre")
		parse(post, "post")
		for (name in names) {
			dactive = post_active[name] - pre_active[name]
			devent = post_event[name] - pre_event[name]
			dwakeup = post_wakeup[name] - pre_wakeup[name]
			dtime = post_time[name] - pre_time[name]
			if (dactive || devent || dwakeup || dtime)
				printf "%-44s %10d %10d %10d %12d\n",
				       name, dactive, devent, dwakeup, dtime
		}
	}' | sort -k4,4nr -k3,3nr
}

print_ddr_deltas() {
	local pre="$1" post="$2"

	printf '%-22s %8s %16s %10s\n' "record" "dCount" "dDur(ticks)" "res(s)"
	awk -v pre="$pre" -v post="$post" -v hz="$TICK_HZ" '
	function field_value(field) {
		sub(/^[^:]*:/, "", field)
		return field
	}
	function parse(text, which, lines, fields, count, i, key, count_field, dur_field) {
		count = split(text, lines, "\n")
		for (i = 1; i <= count; i++) {
			split(lines[i], fields, /[[:space:]]+/)
			if (fields[1] != "DDR")
				continue
			if (fields[2] == "LPM") {
				key = "lpm-" field_value(fields[4])
				count_field = 5
				dur_field = 7
			} else if (fields[2] == "Freq") {
				sub(/:$/, "", fields[3])
				key = "freq-" fields[3] "-cp" field_value(fields[5])
				count_field = 6
				dur_field = 8
			} else {
				continue
			}
			if (which == "pre") {
				pre_count[key] = field_value(fields[count_field])
				pre_dur[key] = field_value(fields[dur_field])
			} else {
				post_count[key] = field_value(fields[count_field])
				post_dur[key] = field_value(fields[dur_field])
				keys[key] = 1
			}
		}
	}
	BEGIN {
		parse(pre, "pre")
		parse(post, "post")
		for (key in keys) {
			dcount = post_count[key] - pre_count[key]
			ddur = post_dur[key] - pre_dur[key]
			printf "%-22s %8d %16d %10.1f\n",
			       key, dcount, ddur, ddur / hz
		}
	}' | sort
}

# energy in uWh from qcom-battmgr, if available
read_energy_uwh() {
	local f=/sys/class/power_supply/qcom-battmgr-bat/energy_now
	[[ -r "$f" ]] && cat "$f" || echo ""
}

{
	echo "kernel:        $KREL"
	echo "kernel_build:  $(uname -v)"
	echo "cmdline:       $(cat /proc/cmdline 2>/dev/null)"
	echo "taint_before:  $(cat /proc/sys/kernel/tainted 2>/dev/null)"
	echo "host:          $(hostname)"
	echo "date:          $(date -Iseconds)"
	echo "tag:           $TAG"
	echo "suspend_secs:  $SUSPEND_SECS"
	echo "usb_wakeup_off_requested: $USB_WAKEUP_OFF"
	echo "stats_only_requested: $XO_STATS_ONLY"
	echo "no_freqsync_requested: $NO_FREQSYNC"
	echo "stats_dir:     $STATS_DIR"
	echo "mem_sleep:     $(cat /sys/power/mem_sleep 2>/dev/null)"
	echo "cpu_latency_qos_us:  $(read_qos_us /dev/cpu_dma_latency)"
	echo "cpu_wakeup_qos_us:   $(read_qos_us /dev/cpu_wakeup_latency)"
	echo
} > "$OUT"

trap xo_capture_stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if ! xo_capture_start >> "$OUT" 2>&1; then
	echo "XO/TCSR capture setup failed; suspend not started. See $OUT" >&2
	exit 1
fi
if (( USB_WAKEUP_OFF )); then
	if ! xo_usb_wakeup_disable >> "$OUT" 2>&1; then
		echo "USB wakeup setup failed; suspend not started. See $OUT" >&2
		exit 1
	fi
	echo 'USB wakeup disabled for this test; use the power button to resume.'
fi

{
	echo '=== pre-suspend USB wakeup policy ==='
	xo_usb_wakeup_snapshot
	echo '=== pre-suspend XO/TCSR clocks ==='
	xo_clock_snapshot
	echo '=== pre-suspend suspend_stats ==='
	xo_suspend_snapshot
} >> "$OUT"

# ---- pre snapshot ----
PRE_BOOT=$(now_boot_s)
PRE_MONO=$(now_mono_only_s)
PRE_E=$(read_energy_uwh)
PRE_JOURNAL_CURSOR=$(journalctl -k -n 0 --show-cursor 2>/dev/null |
	sed -n 's/^-- cursor: //p')
snapshot pre
if (( NO_FREQSYNC )); then PRE_DDR=""; else PRE_DDR=$(read_ddr_stats); fi
PRE_WAKEUP=$(read_wakeup_sources)
PRE_GENPD=$(read_genpd_cpu_domains)
PRE_CPUIDLE=$(read_cpuidle_states)

echo "=== pre-suspend ===" >> "$OUT"
printf 'pre boot=%s mono=%s energy=%s uWh\n' "$PRE_BOOT" "$PRE_MONO" "${PRE_E:-?}" >> "$OUT"
for sub in "${SUBS[@]}"; do
	[[ "${SNAP[pre_${sub}_present]:-0}" == 1 ]] || continue
	printf '  %-14s count=%s dur_ticks=%s entered_ticks=%s exited_ticks=%s\n' "$sub" \
		"${SNAP[pre_${sub}_count]}" "${SNAP[pre_${sub}_dur]}" \
		"${SNAP[pre_${sub}_entered]}" "${SNAP[pre_${sub}_exited]}" >> "$OUT"
done
if [[ -n "$PRE_DDR" ]]; then
	echo "=== pre-suspend DDR stats ===" >> "$OUT"
	printf '%s\n' "$PRE_DDR" >> "$OUT"
fi
if [[ -n "$PRE_WAKEUP" ]]; then
	echo "=== pre-suspend wakeup sources ===" >> "$OUT"
	printf '%s\n' "$PRE_WAKEUP" >> "$OUT"
fi

cat <<EOF | tee -a "$OUT"

*** MANUAL SUSPEND in 5 seconds.
*** When the screen blanks, wait at least ${SUSPEND_SECS}s,
*** then press the POWER BUTTON briefly to resume.
EOF
sleep 5

if ! systemctl suspend --no-block; then
	echo 'Suspend request failed' | tee -a "$OUT"
	exit 1
fi

# Wait for the boottime - monotonic jump to appear and stop growing,
# meaning the kernel has resumed; warn if shorter than SUSPEND_SECS. Use monotonic
# time for the safety deadline so sleeping longer than requested does not
# look like a timeout immediately after resume.
DEADLINE_MONO=$(awk -v m="$PRE_MONO" 'BEGIN{ printf "%.0f", m + 7200 }')
LAST_DELTA=0
while :; do
	sleep 5
	NOW_BOOT=$(now_boot_s)
	NOW_MONO=$(now_mono_only_s)
	# delta accumulates only while suspended
	DELTA=$(awk -v b="$NOW_BOOT" -v m="$NOW_MONO" -v pb="$PRE_BOOT" -v pm="$PRE_MONO" \
		'BEGIN{ printf "%.0f", (b - pb) - (m - pm) }')
	if [[ "$DELTA" -gt 10 && "$DELTA" -eq "$LAST_DELTA" ]]; then
		# stable for one tick after a suspend = we are awake
		if [[ "$DELTA" -lt "$SUSPEND_SECS" ]]; then
			echo "WARNING: woke after ${DELTA}s suspended, requested ${SUSPEND_SECS}s" | tee -a "$OUT"
		fi
		break
	fi
	LAST_DELTA="$DELTA"
	NOW_MONO_INT=$(awk -v m="$NOW_MONO" 'BEGIN{ printf "%.0f", m }')
	[[ "$NOW_MONO_INT" -gt "$DEADLINE_MONO" ]] && { echo "timed out waiting for resume" >> "$OUT"; break; }
done

# ---- post snapshot ----
POST_BOOT=$(now_boot_s)
POST_MONO=$(now_mono_only_s)
POST_E=$(read_energy_uwh)
snapshot post
POST_DDR=$(read_ddr_stats)
POST_WAKEUP=$(read_wakeup_sources)
POST_GENPD=$(read_genpd_cpu_domains)
POST_CPUIDLE=$(read_cpuidle_states)
xo_capture_stop >> "$OUT"

{
	echo '=== post-resume XO/TCSR clocks ==='
	xo_clock_snapshot
	echo '=== post-resume suspend_stats ==='
	xo_suspend_snapshot
	echo '=== restored USB wakeup policy ==='
	xo_usb_wakeup_snapshot
	echo "taint_after: $(cat /proc/sys/kernel/tainted 2>/dev/null)"
} >> "$OUT"

WALL=$(awk -v b="$POST_BOOT" -v pb="$PRE_BOOT" 'BEGIN{ printf "%.0f", b - pb }')
SUSP=$(awk -v b="$POST_BOOT" -v m="$POST_MONO" -v pb="$PRE_BOOT" -v pm="$PRE_MONO" \
	'BEGIN{ printf "%.0f", (b - pb) - (m - pm) }')

{
	echo
	echo "=== post-resume ==="
	printf 'post boot=%s mono=%s energy=%s uWh\n' "$POST_BOOT" "$POST_MONO" "${POST_E:-?}"
	for sub in "${SUBS[@]}"; do
		[[ "${SNAP[post_${sub}_present]:-0}" == 1 ]] || continue
		printf '  %-14s count=%s dur_ticks=%s entered_ticks=%s exited_ticks=%s\n' "$sub" \
			"${SNAP[post_${sub}_count]}" "${SNAP[post_${sub}_dur]}" \
			"${SNAP[post_${sub}_entered]}" "${SNAP[post_${sub}_exited]}"
	done
	printf 'wall total: %ss   suspended: %ss   awake: %ss\n' "$WALL" "$SUSP" "$((WALL-SUSP))"
	if [[ -n "$PRE_E" && -n "$POST_E" ]]; then
		dE=$(( PRE_E - POST_E ))
		W=$(awk -v e="$dE" -v t="$WALL" 'BEGIN{ if (t<=0) print "?"; else printf "%.3f", (e/1e6) * 3600 / t }')
		echo "energy:     ΔE=${dE} uWh / wall=${WALL}s = ${W} W (over full window)"
	fi
	echo
	echo "=== sleep-stats deltas (count / accumulated residency) ==="
	# qcom_stats durations are arch-timer ticks, not ns: qcom_stats.c does
	# accumulated += arch_timer_read_counter() - stat->last_entered_at.
	WALL_TICKS=$(awk -v t="$WALL" -v hz="$TICK_HZ" 'BEGIN{ printf "%.0f", t * hz }')
	printf '%-14s %8s %16s %10s %10s\n' subsystem dCount 'dDur(ticks)' 'res(s)' '%wall'
	for sub in "${SUBS[@]}"; do
		[[ "${SNAP[pre_${sub}_present]:-0}" == 1 ]] || continue
		[[ "${SNAP[post_${sub}_present]:-0}" == 1 ]] || continue
		pc="${SNAP[pre_${sub}_count]}"
		pd="${SNAP[pre_${sub}_dur]}"
		qc="${SNAP[post_${sub}_count]}"
		qd="${SNAP[post_${sub}_dur]}"
		dc=$((qc - pc))
		dd=$((qd - pd))
		# qcom_stats augments an apparently active record with the live
		# arch counter. Some firmware leaves entered a few ticks newer than
		# exited while awake, inflating the pre-read. For exactly one
		# completed interval, its timestamps are the authoritative delta.
		qe="${SNAP[post_${sub}_entered]}"
		qx="${SNAP[post_${sub}_exited]}"
		if [[ "$dc" -eq 1 && "$qx" -ge "$qe" ]]; then
			dd=$((qx - qe))
		fi
		# APSS cannot be asleep while the AP reads it: no new entry means no residency.
		if [[ "$sub" == apss && "$dc" -eq 0 ]]; then
			dd=0
		fi
		[[ "$sub" == apss ]] && APSS_DD="$dd"
		res_s=$(awk -v d="$dd" -v hz="$TICK_HZ" 'BEGIN{ printf "%.1f", d/hz }')
		pct=$(awk -v d="$dd" -v w="$WALL_TICKS" 'BEGIN{ if (w<=0) print "?"; else printf "%.1f", 100*d/w }')
		printf '%-14s %8s %16s %10s %10s\n' "$sub" "$dc" "$dd" "$res_s" "$pct"
	done
	if [[ -n "$POST_DDR" ]]; then
		echo
		echo "=== post-resume DDR stats ==="
		printf '%s\n' "$POST_DDR"
		echo
		echo "=== DDR deltas ==="
		print_ddr_deltas "$PRE_DDR" "$POST_DDR"
	fi
	if [[ -n "$POST_WAKEUP" ]]; then
		echo
		echo "=== post-resume wakeup sources ==="
		printf '%s\n' "$POST_WAKEUP"
		echo
		echo "=== wakeup-source deltas ==="
		print_wakeup_deltas "$PRE_WAKEUP" "$POST_WAKEUP"
	fi
	if [[ -n "$POST_GENPD" ]]; then
		echo
		echo "=== CPU PM-domain idle-state deltas (genpd) ==="
		printf '%-26s %-7s %10s %10s %10s\n' domain state dUsage dRejected dS2idle
		print_counter_deltas "$PRE_GENPD" "$POST_GENPD" "4 5 8"
	fi
	if [[ -n "$POST_CPUIDLE" ]]; then
		echo
		echo "=== per-CPU cpuidle deltas ==="
		printf '%-26s %-7s %10s %10s %10s\n' cpu state dUsage dRejected dS2idle
		print_counter_deltas "$PRE_CPUIDLE" "$POST_CPUIDLE" "3 4 5"
	fi
	echo
	echo "=== suspend TCS kernel log ==="
	grep -E 'PM: suspend (entry|exit)|system-suspend-(pre|post)|rpmh_flush|Skipping flush|WARNING:|BUG:|Call trace:' "$XO_KERNEL_OUT" ||
		echo 'no matching records; see raw kernel log'
	echo
	echo '=== XO/TCSR validation ==='
	echo "kernel_log: $XO_KERNEL_OUT"
	if (( XO_STATS_ONLY )); then
		echo 'XO_SLEEP_REQUEST: NOT_MEASURED (stats-only; no tracing enabled)'
		echo 'TCSR_OUTPUTS_AT_ENTRY: NOT_MEASURED (stats-only; boundary snapshots only)'
	else
		echo "trace: $XO_TRACE_OUT"
		echo "trace_stats: $XO_TRACE_STATS (lost events: $XO_TRACE_LOSS)"
		xo_validate "$OUT" "$XO_TRACE_OUT" "$XO_KERNEL_OUT" "$XO_TRACE_LOSS"
	fi
	echo
	echo "=== summary (one-line) ==="
	# Quick diagnosis: APSS residency tells us how long the AP was in
	# system sleep; subsystem residencies > APSS means they slept on
	# their own (good); < APSS means a subsystem was awake while the
	# AP was sleeping (bad).
	apss_dd="${APSS_DD:-0}"
	apss_pct=$(awk -v d="$apss_dd" -v w="$WALL_TICKS" 'BEGIN{ if (w<=0) print "?"; else printf "%.1f", 100*d/w }')
	echo "kernel=$KREL tag=$TAG wall=${WALL}s suspend=${SUSP}s apss_residency=${apss_pct}% (dur_ticks=${apss_dd})"
	aosd_d=$(( ${SNAP[post_aosd_count]:-0} - ${SNAP[pre_aosd_count]:-0} ))
	cxsd_d=$(( ${SNAP[post_cxsd_count]:-0} - ${SNAP[pre_cxsd_count]:-0} ))
	ddr_d=$(( ${SNAP[post_ddr_count]:-0} - ${SNAP[pre_ddr_count]:-0} ))
	lpm_d=$(awk -v a="$(ddr_lpm_ticks "$PRE_DDR")" -v b="$(ddr_lpm_ticks "$POST_DDR")" 'BEGIN{ printf "%.0f", b - a }')
	if (( aosd_d > 0 || cxsd_d > 0 || ddr_d > 0 || lpm_d > 0 )); then verdict=YES; else verdict=NO; fi
	echo "COLLAPSE: $verdict (aosd +$aosd_d, cxsd +$cxsd_d, ddr +$ddr_d, DDR LPM d4/d3/11 +$lpm_d ticks$( (( NO_FREQSYNC )) && echo ' since boot'))"
} >> "$OUT"

echo
grep -E '^(XO_SLEEP_REQUEST:|XO clock prepare|TCSR_OUTPUTS_AT_ENTRY:)' "$OUT"
tail -n 1 "$OUT"
echo "wrote $OUT"
if (( XO_USB_RESTORE_FAILED )); then
	echo 'USB wakeup restoration failed; restore the settings listed in the warnings.' >&2
	exit 1
fi
