#!/bin/bash
# Capture Qualcomm sleep-stat deltas across a manual suspend cycle.
#
# Reads /sys/kernel/debug/qcom_stats/{apss,adsp,cdsp,modem,slpi,gpu,...}
# before suspend and after resume, computes the delta in count and
# accumulated duration, and reports residency % of wall time.
#
# Usage: sudo ./xps-rpmh-stats.sh [TAG] [-s SUSPEND_SECS] [--manual] [--power] [--usb-wakeup-off] [--stats-only] [--no-freqsync] [--smp2p-wake]
#   TAG: free-form label for the output log (default: rpmh)
#   SUSPEND_SECS: target seconds in suspend; waking earlier is reported, not waited out (default: 600)
#
# The pm8xxx RTC has no wakeup. By default the script requests suspend
# with `systemctl suspend --no-block`; wake it yourself after the target interval.
# --manual takes the pre-snapshot and waits for you to close the lid instead.
# Leave the terminal running. After wake, suspend_stats or a
# CLOCK_BOOTTIME-vs-MONOTONIC jump triggers the post-snapshot automatically.
# This standalone tool reads residency counters without enabling tracing,
# dynamic debug or clock snapshots. No companion helper is loaded.
# --usb-wakeup-off temporarily disables wakeup on the three USB controllers.
# USB devices cannot wake this test; use the power button. Prior settings are restored.
# --stats-only is accepted for compatibility; statistics-only capture is the default.
# --no-freqsync skips the pre-suspend ddr_stats read; every read sends the AOP
# {class: ddr, action: freqsync}. DDR LPM is then reported since boot.
# --smp2p-wake disables ADSP/CDSP automatic recovery, then enables their incoming
# SMP2P wake sources. Readback is checked before suspend and after resume.
# Use after a cold boot: this does not clear poison or arm hardware-watchdog IRQs.
# These policies remain set after exit/cancellation until reboot; recovery is
# NOT automatically restored because enabling it can immediately restart a DSP.
# -s is a duration to aim for, not a wake timer or a post-resume delay.
# Waiting times out after two awake hours; Ctrl-C cancels and cleans up capture.
# --power measures suspend power with a temporary systemd pre/post sleep hook.
# It includes entry/resume energy, but excludes waiting to close/unlock the lid.

set -u

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
	sed -n '2,/^$/p' "$0"
	exit 0
fi

if [[ $EUID -ne 0 ]]; then
	echo "must run as root (debugfs needs it)" >&2
	exit 1
fi

STATS_DIR=/sys/kernel/debug/qcom_stats
SUSPEND_DIR=/sys/power/suspend_stats
LOCK_FILE=/run/lock/xps-rpmh-stats.lock
CAPTURE_STOPPED=0
USB_ROOT=/sys/bus/platform/devices
USB_CONTROLLERS=(a400000.usb a600000.usb a800000.usb)
USB_CHANGED=()
USB_RESTORE_FAILED=0
declare -A USB_SAVED=()
SMP2P_RPROC_DIR=/sys/class/remoteproc
SMP2P_PLATFORM_DIR=/sys/devices/platform
if [[ ! -d "$STATS_DIR" ]]; then
	echo "missing $STATS_DIR — qcom_stats debugfs not present" >&2
	exit 1
fi

TAG="rpmh"
SUSPEND_SECS=600
MANUAL=0
POWER=0
POWER_HOOK=
POWER_DIR=
POWER_FAILED=0
USB_WAKEUP_OFF=0
NO_FREQSYNC=0
SMP2P_WAKE=0
SMP2P_VERIFY_FAILED=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		-s) SUSPEND_SECS="$2"; shift 2 ;;
		--manual) MANUAL=1; shift ;;
		--power) POWER=1; shift ;;
		--usb-wakeup-off) USB_WAKEUP_OFF=1; shift ;;
		--stats-only) shift ;;
		--usb-wake-trace) echo '--usb-wake-trace has been removed; this tool does not enable tracing' >&2; exit 2 ;;
		--no-freqsync) NO_FREQSYNC=1; shift ;;
		--smp2p-wake) SMP2P_WAKE=1; shift ;;
		-h|--help)
			sed -n '2,/^$/p' "$0"; exit 0 ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) TAG="$1"; shift ;;
	esac
done

KREL="$(uname -r)"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-$(cd "$(dirname "$0")/.." && pwd)/logs}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/rpmh-${KREL}-${TAG}-${TS}-$$.log"
KERNEL_OUT="${OUT%.log}.kernel.log"

suspend_snapshot() {
	local field value
	for field in success fail last_failed_dev last_failed_errno; do
		value=$(cat "$SUSPEND_DIR/$field" 2>/dev/null) || value=unavailable
		printf '%s: %s\n' "$field" "$value"
	done
}

usb_wakeup_write() {
	local path=$1 value=$2 observed
	printf '%s\n' "$value" > "$path" || return 1
	observed=$(cat "$path") || return 1
	[[ "$observed" == "$value" ]]
}

usb_wakeup_snapshot() {
	local controller value
	for controller in "${USB_CONTROLLERS[@]}"; do
		value=$(cat "$USB_ROOT/$controller/power/wakeup" 2>/dev/null) || value=unavailable
		printf '%s power/wakeup=%s\n' "$controller" "$value"
	done
}

usb_wakeup_disable() {
	local controller path value
	for controller in "${USB_CONTROLLERS[@]}"; do
		path="$USB_ROOT/$controller/power/wakeup"
		[[ -r "$path" && -w "$path" ]] || { echo "USB wakeup control unavailable: $path"; return 1; }
		value=$(cat "$path") || return 1
		[[ "$value" == enabled || "$value" == disabled ]] || { echo "Invalid USB wakeup state: $path=$value"; return 1; }
		USB_SAVED["$path"]=$value
	done
	for controller in "${USB_CONTROLLERS[@]}"; do
		path="$USB_ROOT/$controller/power/wakeup"
		echo "USB wakeup original: $controller=${USB_SAVED[$path]}"
		[[ ${USB_SAVED[$path]} == enabled ]] || continue
		USB_CHANGED+=("$path")
		usb_wakeup_write "$path" disabled || return 1
	done
}

usb_wakeup_restore() {
	local path failed=0
	for path in "${USB_CHANGED[@]}"; do
		if usb_wakeup_write "$path" "${USB_SAVED[$path]}"; then
			echo "USB wakeup restored: $path=${USB_SAVED[$path]}"
		else
			echo "WARNING: restore $path to ${USB_SAVED[$path]} manually" >&2
			USB_RESTORE_FAILED=1
			failed=1
		fi
	done
	USB_CHANGED=()
	return "$failed"
}

capture_start() {
	exec {CAPTURE_LOCK_FD}>"$LOCK_FILE" || return 1
	flock -n "$CAPTURE_LOCK_FD" || {
		echo 'Another residency capture is running' >&2
		return 1
	}
}

capture_stop() {
	(( CAPTURE_STOPPED )) && return 0
	CAPTURE_STOPPED=1
	usb_wakeup_restore || true
	if [[ -n ${PRE_JOURNAL_CURSOR:-} ]]; then
		journalctl -k -b --no-pager -o short-monotonic \
			--after-cursor="$PRE_JOURNAL_CURSOR" > "$KERNEL_OUT" 2>&1 || true
	fi
	if [[ -n ${CAPTURE_LOCK_FD:-} ]]; then
		flock -u "$CAPTURE_LOCK_FD"
		exec {CAPTURE_LOCK_FD}>&-
		CAPTURE_LOCK_FD=
	fi
}

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

declare -A SMP2P_REMOTES=()

smp2p_write_verify() {
	local path=$1 expected=$2 observed
	printf '%s\n' "$expected" > "$path" || {
		echo "Failed to write $path=$expected" >&2
		return 1
	}
	observed=$(cat "$path") || return 1
	if [[ "$observed" != "$expected" ]]; then
		echo "SMP2P readback mismatch: $path=$observed (expected $expected)" >&2
		return 1
	fi
	echo "SMP2P verified: $path=$observed"
}

smp2p_wake_setup() {
	local remote name state recovery wake path
	SMP2P_REMOTES=()
	echo '=== SMP2P wake/recovery setup ==='
	echo 'Cold boot required for an unpoisoned test; this does not clear poison.'
	echo 'Applied settings persist until reboot, including after errors or cancellation.'
	echo 'Automatic recovery will not be restored; do not request recovery at EL2.'
	for remote in "$SMP2P_RPROC_DIR"/remoteproc*; do
		[[ -d "$remote" ]] || continue
		name=$(cat "$remote/name") || return 1
		[[ "$name" == adsp || "$name" == cdsp ]] || continue
		if [[ -v SMP2P_REMOTES[$name] ]]; then
			echo "Ambiguous remoteproc name: $name" >&2
			return 1
		fi
		SMP2P_REMOTES[$name]=$remote
	done

	# Preflight both processors before making any changes.
	for name in adsp cdsp; do
		remote=${SMP2P_REMOTES[$name]:-}
		if [[ -z "$remote" ]]; then
			echo "Missing $name remoteproc" >&2
			return 1
		fi
		for path in "$remote/recovery" "$SMP2P_PLATFORM_DIR/smp2p-$name/power/wakeup"; do
			if [[ ! -r "$path" || ! -w "$path" ]]; then
				echo "SMP2P policy control unavailable: $path" >&2
				return 1
			fi
		done
		state=$(cat "$remote/state") || return 1
		recovery=$(cat "$remote/recovery") || return 1
		wake=$(cat "$SMP2P_PLATFORM_DIR/smp2p-$name/power/wakeup") || return 1
		echo "$name original: remoteproc=$remote state=$state recovery=$recovery wakeup=$wake"
		if [[ "$state" != running && "$state" != attached ]]; then
			echo "$name is not running or attached; cold boot before testing" >&2
			return 1
		fi
		if [[ "$recovery" != enabled && "$recovery" != disabled ]] ||
		   [[ "$wake" != enabled && "$wake" != disabled ]]; then
			echo "Invalid $name recovery or wakeup policy" >&2
			return 1
		fi
	done
	# Verify recovery is disabled on both before enabling either wake source.
	for name in adsp cdsp; do
		smp2p_write_verify "${SMP2P_REMOTES[$name]}/recovery" disabled || return 1
	done
	for name in adsp cdsp; do
		smp2p_write_verify "$SMP2P_PLATFORM_DIR/smp2p-$name/power/wakeup" enabled || return 1
	done
	smp2p_wake_verify configured
}

smp2p_wake_verify() {
	local phase=$1 name remote observed state recovery wake failed=0
	echo "=== $phase SMP2P wake/recovery verification ==="
	for name in adsp cdsp; do
		remote=${SMP2P_REMOTES[$name]}
		observed=$(cat "$remote/name") || return 1
		state=$(cat "$remote/state") || return 1
		recovery=$(cat "$remote/recovery") || return 1
		wake=$(cat "$SMP2P_PLATFORM_DIR/smp2p-$name/power/wakeup") || return 1
		echo "$name verified: remoteproc=$remote name=$observed state=$state recovery=$recovery wakeup=$wake"
		if [[ "$observed" != "$name" || "$recovery" != disabled || "$wake" != enabled ]] ||
		   [[ "$state" != running && "$state" != attached ]]; then
			echo "SMP2P verification failed for $name: expected running/attached, recovery=disabled, wakeup=enabled" >&2
			failed=1
		fi
	done
	return "$failed"
}

power_capture_start() {
	POWER_DIR=$(mktemp -d "${OUT%.log}.power.XXXXXX") || return 1
	POWER_HOOK=$(mktemp /usr/lib/systemd/system-sleep/90-xps-rpmh-power.XXXXXX) || return 1
	{
		printf '#!/bin/bash\nset -eu\n'
		printf 'kill -0 %q 2>/dev/null || exit 0\n' "$$"
		printf 'cd %q\n' "$POWER_DIR"
		cat <<'HOOK'
[[ $2 == suspend ]] || exit 0
case $1 in pre|post) ;; *) exit 1 ;; esac
exec 2>>error.log
test ! -e "$1" || { echo "Duplicate $1 sample" >&2; exit 1; }
python3 - "$1" > "$1.tmp" <<'PY'
from pathlib import Path
import time
bat = Path("/sys/class/power_supply/qcom-battmgr-bat")
energy = int((bat / "energy_now").read_text())
boot = time.clock_gettime(time.CLOCK_BOOTTIME)
mono = time.clock_gettime(time.CLOCK_MONOTONIC)
status = (bat / "status").read_text().strip()
print(energy, boot, mono, status)
PY
mv "$1.tmp" "$1"
HOOK
	} > "$POWER_HOOK" || return 1
	chmod 0700 "$POWER_HOOK" || return 1
	echo "Suspend power capture armed: $POWER_DIR"
}

capture_cleanup() {
	if [[ -n "$POWER_HOOK" ]]; then
		rm -f -- "$POWER_HOOK" || {
			echo "Remove temporary sleep hook manually: $POWER_HOOK" >&2
			return 1
		}
		POWER_HOOK=
	fi
	capture_stop
}

power_capture_report() {
	local attempt e0 b0 m0 s0 e1 b1 m1 s1
	for ((attempt=0; attempt<150; attempt++)); do
		[[ -f "$POWER_DIR/post" || -s "$POWER_DIR/error.log" ]] && break
		sleep 0.2
	done
	if [[ -s "$POWER_DIR/error.log" || ! -f "$POWER_DIR/pre" || ! -f "$POWER_DIR/post" ]]; then
		echo "SUSPEND_POWER: INVALID (missing or failed hook sample; see $POWER_DIR)"
		return 1
	fi
	read -r e0 b0 m0 s0 < "$POWER_DIR/pre" || return 1
	read -r e1 b1 m1 s1 < "$POWER_DIR/post" || return 1
	if [[ $s0 != Discharging || $s1 != Discharging ]]; then
		echo "SUSPEND_POWER: INVALID (battery status $s0 -> $s1)"
		return 1
	fi
	awk -v e0="$e0" -v e1="$e1" -v b0="$b0" -v b1="$b1" -v m0="$m0" -v m1="$m1" '
	BEGIN {
		elapsed = b1-b0
		suspended = elapsed-(m1-m0)
		if (elapsed <= 0 || suspended <= 0 || e0 <= e1) {
			print "SUSPEND_POWER: INVALID (no measurable discharge or suspended interval)"
			exit 1
		}
		printf "SUSPEND_POWER: %.3f W (%d uWh / %.3f s; pre/post sleep hooks)\n", (e0-e1)/1e6*3600/elapsed, e0-e1, elapsed
		printf "POWER_SAMPLE_TIMING: suspended=%.3f s; entry/resume=%.3f s\n", suspended, m1-m0
	}'
}

print_suspend_measurement() {
	local wall suspended awake sub ticks count seconds pct
	read -r wall suspended awake < <(
		awk -v b="$POST_BOOT" -v pb="$PRE_BOOT" -v m="$POST_MONO" -v pm="$PRE_MONO" \
			'BEGIN { printf "%.9f %.9f %.9f\n", b-pb, (b-pb)-(m-pm), m-pm }'
	)
	printf 'SUSPEND_TIME: %.3f s\n' "$suspended"
	printf 'AWAKE_OVERHEAD: %.3f s\n' "$awake"
	for sub in aosd cxsd ddr; do
		if [[ ! -v SNAP[delta_${sub}_dur] ]]; then
			echo "${sub^^}_RESIDENCY: NOT_MEASURED (missing counter snapshot)"
			continue
		fi
		ticks=${SNAP[delta_${sub}_dur]}
		count=${SNAP[delta_${sub}_count]}
		if (( ticks < 0 || count < 0 )); then
			echo "${sub^^}_RESIDENCY: INVALID (counter decreased)"
			continue
		fi
		seconds=$(awk -v d="$ticks" -v hz="$TICK_HZ" 'BEGIN { printf "%.3f", d/hz }')
		pct=$(awk -v d="$ticks" -v hz="$TICK_HZ" -v s="$suspended" \
			'BEGIN { if (s <= 0) print "NOT_MEASURED"; else printf "%.3f%%", 100*d/hz/s }')
		echo "${sub^^}_RESIDENCY: ${seconds} s / suspended = $pct; entries +$count"
	done
	if [[ -n "$PRE_E" && -n "$POST_E" ]]; then
		awk -v e="$((PRE_E-POST_E))" -v t="$wall" 'BEGIN {
			if (t <= 0) {
				print "BATTERY_WINDOW: INVALID (nonpositive elapsed time)"
			} else {
				printf "BATTERY_WINDOW: net energy decrease %d uWh / %.3f s = %.3f W\n", e, t, e/1e6*3600/t
			}
		}'
	else
		echo 'BATTERY_WINDOW: NOT_MEASURED (missing energy sample)'
	fi
	if (( POWER )); then
		power_capture_report || POWER_FAILED=1
	elif [[ -n "$PRE_E" && -n "$POST_E" ]]; then
		# No sleep hook: fall back to the capture's own energy samples, which
		# include the ~10 s awake around the suspend.
		awk -v e="$((PRE_E-POST_E))" -v t="$wall" 'BEGIN {
			if (t <= 0 || e <= 0)
				print "SUSPEND_POWER: INVALID (no measurable discharge in battery window)"
			else
				printf "SUSPEND_POWER: %.3f W (%d uWh / %.3f s; battery window incl. awake, no hook)\n", e/1e6*3600/t, e, t
		}'
	else
		echo 'SUSPEND_POWER: NOT_MEASURED (missing energy sample)'
	fi
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
	echo "manual_mode:   $MANUAL"
	echo "power_mode:    $POWER"
	echo "usb_wakeup_off_requested: $USB_WAKEUP_OFF"
	echo 'capture_mode: stats-only'
	echo "no_freqsync_requested: $NO_FREQSYNC"
	echo "smp2p_wake_requested: $SMP2P_WAKE"
	echo "stats_dir:     $STATS_DIR"
	echo "mem_sleep:     $(cat /sys/power/mem_sleep 2>/dev/null)"
	echo "cpu_latency_qos_us:  $(read_qos_us /dev/cpu_dma_latency)"
	echo "cpu_wakeup_qos_us:   $(read_qos_us /dev/cpu_wakeup_latency)"
	echo
} > "$OUT"

trap capture_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if ! capture_start >> "$OUT" 2>&1; then
	echo "Capture setup failed; suspend not started. See $OUT" >&2
	exit 1
fi
if (( POWER )) && ! power_capture_start >> "$OUT" 2>&1; then
	echo "Power capture setup failed; see $OUT" >&2
	exit 1
fi
if (( USB_WAKEUP_OFF )); then
	if ! usb_wakeup_disable >> "$OUT" 2>&1; then
		echo "USB wakeup setup failed; suspend not started. See $OUT" >&2
		exit 1
	fi
	echo 'USB wakeup disabled for this test; use the power button to resume.'
fi
if (( SMP2P_WAKE )); then
	if ! smp2p_wake_setup >> "$OUT" 2>&1; then
		echo "SMP2P setup failed; suspend not started. Settings may be partly applied and are not restored. See $OUT" >&2
		exit 1
	fi
	echo 'SMP2P wake enabled and recovery disabled for both DSPs (readback verified).'
	echo 'These settings persist until reboot; start from a cold boot, not a poisoned warm boot.'
fi

{
	echo '=== pre-suspend USB wakeup policy ==='
	usb_wakeup_snapshot
	echo '=== pre-suspend suspend_stats ==='
	suspend_snapshot
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

# ---- suspend request ----
PRE_SUCCESS=$(cat "$SUSPEND_DIR/success") || exit 1
PRE_FAIL=$(cat "$SUSPEND_DIR/fail") || exit 1

if (( SMP2P_WAKE )) && ! smp2p_wake_verify pre-suspend >> "$OUT" 2>&1; then
	echo "SMP2P verification failed; suspend not started. See $OUT" >&2
	exit 1
fi

if (( MANUAL )); then
	cat <<EOF | tee -a "$OUT"

*** Pre-suspend snapshot saved: $OUT
*** Ready: close the lid to suspend. This script will NOT request suspend.
*** Leave this terminal running; wake after about ${SUSPEND_SECS}s.
*** The post-resume snapshot and deltas will be captured automatically.
EOF
else
	cat <<EOF | tee -a "$OUT"

*** SUSPEND in 5 seconds (manual wake).
*** When the screen blanks, wait at least ${SUSPEND_SECS}s,
*** then press the POWER BUTTON briefly to resume.
EOF
	sleep 5

	if (( SMP2P_WAKE )) && ! smp2p_wake_verify pre-request >> "$OUT" 2>&1; then
		echo "SMP2P verification failed; suspend not started. See $OUT" >&2
		exit 1
	fi
	if ! systemctl suspend --no-block; then
		echo 'Suspend request failed' | tee -a "$OUT"
		exit 1
	fi
fi

# The counters also catch short sleeps and failed attempts with no clock jump.
# Use awake time for the deadline so a long sleep cannot cause a timeout.
DEADLINE_MONO=$(awk -v m="$PRE_MONO" 'BEGIN{ printf "%.0f", m + 7200 }')
LAST_DELTA=0
while :; do
	sleep 5
	NOW_BOOT=$(now_boot_s)
	NOW_MONO=$(now_mono_only_s)
	NOW_SUCCESS=$(cat "$SUSPEND_DIR/success") || exit 1
	NOW_FAIL=$(cat "$SUSPEND_DIR/fail") || exit 1
	# delta accumulates only while suspended
	DELTA=$(awk -v b="$NOW_BOOT" -v m="$NOW_MONO" -v pb="$PRE_BOOT" -v pm="$PRE_MONO" \
		'BEGIN{ printf "%.0f", (b - pb) - (m - pm) }')
	if (( NOW_SUCCESS > PRE_SUCCESS || NOW_FAIL > PRE_FAIL )) ||
	   [[ "$DELTA" -gt 10 && "$DELTA" -eq "$LAST_DELTA" ]]; then
		if (( NOW_FAIL > PRE_FAIL )); then
			echo 'WARNING: suspend failed; see post-resume suspend_stats.' | tee -a "$OUT"
		fi
		if [[ "$DELTA" -lt "$SUSPEND_SECS" ]]; then
			echo "WARNING: woke after ${DELTA}s suspended, requested ${SUSPEND_SECS}s" | tee -a "$OUT"
		fi
		break
	fi
	LAST_DELTA="$DELTA"
	NOW_MONO_INT=$(awk -v m="$NOW_MONO" 'BEGIN{ printf "%.0f", m }')
	if [[ "$NOW_MONO_INT" -gt "$DEADLINE_MONO" ]]; then
		echo 'Timed out waiting for a suspend/resume cycle; no post-snapshot.' | tee -a "$OUT" >&2
		exit 1
	fi
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
capture_stop >> "$OUT"

if (( SMP2P_WAKE )) && ! smp2p_wake_verify post-resume >> "$OUT" 2>&1; then
	echo "SMP2P post-resume verification failed; capture retained. See $OUT" >&2
	SMP2P_VERIFY_FAILED=1
fi

{
	echo '=== post-resume suspend_stats ==='
	suspend_snapshot
	echo '=== restored USB wakeup policy ==='
	usb_wakeup_snapshot
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
		SNAP[delta_${sub}_dur]=$dd
		SNAP[delta_${sub}_count]=$dc
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
	echo "=== suspend kernel log ==="
	grep -E 'PM: suspend (entry|exit)|system-suspend-(pre|post)|WARNING:|BUG:|Call trace:' "$KERNEL_OUT" ||
		echo 'no matching records; see raw kernel log'
	echo
	echo "kernel_log: $KERNEL_OUT"
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
	echo
	echo '=== suspend measurement ==='
	print_suspend_measurement
} >> "$OUT"

echo
grep -E '^(COLLAPSE:|SUSPEND_TIME:|AWAKE_OVERHEAD:|AOSD_RESIDENCY:|CXSD_RESIDENCY:|DDR_RESIDENCY:|SUSPEND_POWER:|POWER_SAMPLE_TIMING:)' "$OUT"
echo "wrote $OUT"
if (( USB_RESTORE_FAILED )); then
	echo 'USB wakeup restoration failed; restore the settings listed in the warnings.' >&2
	exit 1
fi
(( POWER_FAILED == 0 )) || exit 1
(( SMP2P_VERIFY_FAILED == 0 )) || exit 1
