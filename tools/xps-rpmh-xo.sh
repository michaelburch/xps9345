#!/usr/bin/env bash

xo_clock_snapshot() {
	local clock_dir clock_name field value found=0
	printf '%-34s %12s %12s\n' clock prepare_count enable_count
	for clock_dir in "$XO_CLK_DIR"/bi_tcxo "$XO_CLK_DIR"/bi_tcxo_ao "$XO_CLK_DIR"/tcsr_*; do
		[[ -d "$clock_dir" ]] || continue
		found=1
		clock_name=${clock_dir##*/}
		printf '%-34s' "$clock_name"
		for field in clk_prepare_count clk_enable_count; do
			value=$(cat "$clock_dir/$field" 2>/dev/null) || value=unavailable
			printf ' %12s' "$value"
		done
		printf '\n'
	done
	(( found )) || echo 'XO/TCSR clock counters unavailable'
	echo 'Software counts at this boundary only; not an in-sleep clock measurement.'
}

xo_suspend_snapshot() {
	local field value
	for field in success fail last_failed_dev last_failed_errno; do
		value=$(cat "$XO_SUSPEND_DIR/$field" 2>/dev/null) || value=unavailable
		printf '%s: %s\n' "$field" "$value"
	done
}

XO_TRACE_INSTANCE=
XO_DEBUG_LINES=()
XO_TRACE_LOSS=unknown
XO_CAPTURE_STOPPED=0
XO_USB_ROOT=/sys/bus/platform/devices
XO_USB_CONTROLLERS=(a400000.usb a600000.usb a800000.usb)
XO_USB_CHANGED=()
XO_USB_RESTORE_FAILED=0
declare -A XO_USB_SAVED=()

xo_usb_wakeup_write() {
	local path=$1 value=$2 observed
	printf '%s\n' "$value" > "$path" || return 1
	observed=$(cat "$path") || return 1
	[[ "$observed" == "$value" ]]
}

xo_usb_wakeup_snapshot() {
	local controller value
	for controller in "${XO_USB_CONTROLLERS[@]}"; do
		value=$(cat "$XO_USB_ROOT/$controller/power/wakeup" 2>/dev/null) || value=unavailable
		printf '%s power/wakeup=%s\n' "$controller" "$value"
	done
}

xo_usb_wakeup_disable() {
	local controller path value
	for controller in "${XO_USB_CONTROLLERS[@]}"; do
		path="$XO_USB_ROOT/$controller/power/wakeup"
		[[ -r "$path" && -w "$path" ]] || { echo "USB wakeup control unavailable: $path"; return 1; }
		value=$(cat "$path") || return 1
		[[ "$value" == enabled || "$value" == disabled ]] || { echo "Invalid USB wakeup state: $path=$value"; return 1; }
		XO_USB_SAVED["$path"]=$value
	done
	for controller in "${XO_USB_CONTROLLERS[@]}"; do
		path="$XO_USB_ROOT/$controller/power/wakeup"
		echo "USB wakeup original: $controller=${XO_USB_SAVED[$path]}"
		[[ ${XO_USB_SAVED[$path]} == enabled ]] || continue
		XO_USB_CHANGED+=("$path")
		xo_usb_wakeup_write "$path" disabled || { echo "Failed to disable USB wakeup: $path"; return 1; }
	done
}

xo_usb_wakeup_restore() {
	local path failed=0
	for path in "${XO_USB_CHANGED[@]}"; do
		if xo_usb_wakeup_write "$path" "${XO_USB_SAVED[$path]}"; then
			echo "USB wakeup restored: $path=${XO_USB_SAVED[$path]}"
		else
			echo "WARNING: restore $path to ${XO_USB_SAVED[$path]} manually" >&2
			XO_USB_RESTORE_FAILED=1
			failed=1
		fi
	done
	XO_USB_CHANGED=()
	return "$failed"
}

xo_capture_cleanup() {
	local line
	xo_usb_wakeup_restore || true
	for line in "${XO_DEBUG_LINES[@]}"; do
		printf 'file drivers/soc/qcom/rpmh.c line %s -p\n' "$line" > "$XO_DYNDBG" ||
			echo "WARNING: could not restore RPMh debug line $line" >&2
	done
	XO_DEBUG_LINES=()
	if [[ -n "$XO_TRACE_INSTANCE" ]]; then
		echo 0 > "$XO_TRACE_INSTANCE/tracing_on" 2>/dev/null || true
		echo 0 > "$XO_TRACE_INSTANCE/events/enable" 2>/dev/null || true
		rmdir "$XO_TRACE_INSTANCE" 2>/dev/null || true
		XO_TRACE_INSTANCE=
	fi
	if [[ -n ${XO_LOCK_FD:-} ]]; then
		flock -u "$XO_LOCK_FD"
		exec {XO_LOCK_FD}>&-
		unset XO_LOCK_FD
	fi
}

xo_capture_start() {
	local instance event line flags address trace_path tracing tracer events
	local -a sites
	exec {XO_LOCK_FD}>"$XO_LOCK_FILE" || return 1
	flock -n "$XO_LOCK_FD" || { echo 'Another RPMh stats capture is running'; return 1; }
	if [[ ${XO_STATS_ONLY:-0} == 1 ]]; then
		if [[ -r "$XO_DYNDBG" ]] && awk '
			$1 ~ /^drivers\/soc\/qcom\/rpmh(-rsc)?\.c:[0-9]+$/ && $3 ~ /p/ { enabled=1 }
			END { exit !enabled }' "$XO_DYNDBG"; then
			echo 'Stats-only refused: RPMh dynamic-debug printing is already enabled.'
			return 1
		fi
		for trace_path in "$XO_TRACE_ROOT" "$XO_TRACE_ROOT"/instances/*; do
			[[ -r "$trace_path/tracing_on" ]] || continue
			tracing=$(cat "$trace_path/tracing_on") || return 1
			[[ "$tracing" == 1 ]] || continue
			tracer=$(cat "$trace_path/current_tracer") || return 1
			events=$(cat "$trace_path/events/enable") || return 1
			if [[ "$tracer" != nop || "$events" != 0 ]]; then
				echo "Stats-only refused: another trace is active at $trace_path"
				return 1
			fi
		done
		echo 'Stats-only: no XO/TCSR trace or RPMh dynamic-debug printing enabled.'
		return 0
	fi
	address=$(awk '$2 == "xo.lvl" { sub(/:$/, "", $1); print $1 }' "$XO_CMD_DB") || return 1
	[[ "$address" == 0x300e0 ]] || { echo "Unexpected or missing xo.lvl address: $address"; return 1; }
	echo "XO resource: xo.lvl=$address (cmd-db verified); APPS requests only"
	instance="$XO_TRACE_ROOT/instances/xps-rpmh-stats-$$"
	mkdir "$instance" || return 1
	XO_TRACE_INSTANCE=$instance
	echo 0 > "$instance/tracing_on" || return 1
	echo mono > "$instance/trace_clock" || return 1
	echo 256 > "$instance/buffer_size_kb" || return 1
	printf 'addr == 0x300e0 && name == "apps_rsc"\n' > "$instance/events/rpmh/rpmh_send_msg/filter" || return 1
	for event in clk_prepare_complete clk_unprepare_complete; do
		printf 'name ~ "tcsr_*" || name == "bi_tcxo" || name == "bi_tcxo_ao"\n' > "$instance/events/clk/$event/filter" || return 1
	done
	for event in rpmh/rpmh_send_msg power/suspend_resume clk/clk_prepare_complete clk/clk_unprepare_complete; do
		echo 1 > "$instance/events/$event/enable" || return 1
	done
	if [[ -r "$XO_DYNDBG" && -w "$XO_DYNDBG" ]]; then
		mapfile -t sites < <(awk '$1 ~ /^drivers\/soc\/qcom\/rpmh.c:[0-9]+$/ && $2 ~ /\]rpmh_flush$/ {
			split($1, location, ":"); print location[2], $3
		}' "$XO_DYNDBG")
		for event in "${sites[@]}"; do
			read -r line flags <<< "$event"
			[[ "$flags" == *p* ]] && continue
			XO_DEBUG_LINES+=("$line")
			printf 'file drivers/soc/qcom/rpmh.c line %s +p\n' "$line" > "$XO_DYNDBG" || return 1
		done
		echo "RPMh cache debug sites: ${#sites[@]}; existing print flags preserved"
	else
		echo 'RPMh cache debug unavailable; unchanged cached XO requests may be UNKNOWN'
	fi
	echo 1 > "$instance/tracing_on"
}

xo_capture_stop() {
	local stats stopped=0
	(( XO_CAPTURE_STOPPED == 0 )) || return 0
	XO_CAPTURE_STOPPED=1
	if [[ -n "$XO_TRACE_INSTANCE" ]]; then
		if echo 0 > "$XO_TRACE_INSTANCE/tracing_on"; then stopped=1; fi
		if cat "$XO_TRACE_INSTANCE/trace" > "$XO_TRACE_OUT"; then
			: > "$XO_TRACE_STATS"
			for stats in "$XO_TRACE_INSTANCE"/per_cpu/cpu*/stats; do
				printf '%s\n' "$stats" >> "$XO_TRACE_STATS"
				cat "$stats" >> "$XO_TRACE_STATS" 2>/dev/null || echo 'unavailable' >> "$XO_TRACE_STATS"
			done
			XO_TRACE_LOSS=$(awk '/unavailable/ { bad=1 }
				/^(overrun|commit overrun|dropped events):/ { total+=$NF; count++ }
				END { if (bad || !count) print "unknown"; else print total+0 }' "$XO_TRACE_STATS")
		fi
		(( stopped )) || XO_TRACE_LOSS=unknown
	fi
	if [[ -n ${PRE_JOURNAL_CURSOR:-} ]]; then
		journalctl -b 0 -k --after-cursor="$PRE_JOURNAL_CURSOR" --no-pager -o short-monotonic > "$XO_KERNEL_OUT" 2>/dev/null ||
			printf 'journal unavailable\n' > "$XO_KERNEL_OUT"
	else
		printf 'journal cursor unavailable\n' > "$XO_KERNEL_OUT"
	fi
	xo_capture_cleanup
}

xo_validate() {
	local log=$1 trace=$2 kernel_log=$3 loss=$4
	if [[ ! -r "$log" || ! -r "$trace" || ! -r "$kernel_log" ]]; then
		echo 'XO_SLEEP_REQUEST: UNKNOWN (evidence file unavailable)'
		echo 'XO clock prepare state at entry: UNKNOWN'
		echo 'TCSR_OUTPUTS_AT_ENTRY: UNKNOWN'
		return 0
	fi
	awk -v loss="$loss" '
	FILENAME == ARGV[1] {
		if ($0 == "=== pre-suspend XO/TCSR clocks ===") clocks=1
		else if (/^===/) clocks=0
		if (clocks && $1 ~ /^(bi_tcxo(_ao)?|tcsr_.*)$/) {
			known[$1]=($2 ~ /^[0-9]+$/); prepared[$1]=($2+0 > 0)
		}
		if ($0 == "=== pre-suspend suspend_stats ===") phase="pre"
		else if ($0 == "=== post-resume suspend_stats ===") phase="post"
		else if (/^===/) phase=""
		if (phase != "" && $1 ~ /^(success|fail):$/) counters[phase,$1]=$2
		next
	}
	FILENAME == ARGV[2] {
		if (!match($0, / ([0-9]+\.[0-9]+): ([a-z_]+): (.*)$/, fields)) next
		timestamp=fields[1]+0; event=fields[2]; payload=fields[3]
		if (!frozen && event == "suspend_resume" && match(payload, /^CPU_OFF\[([0-9]+)\] end$/, cpu)) last_cpu=cpu[1]
		if (event == "suspend_resume" && payload == "syscore_suspend[0] begin") {
			window=1; start=timestamp; sleep_seen=0; wake_seen=0
		}
		if (event == "suspend_resume" && payload == "machine_suspend[3] begin") {
			begins++; finish=timestamp; window=0; frozen=1
		}
		if (event == "suspend_resume" && payload == "machine_suspend[3] end") ends++
		if (!frozen && event ~ /^clk_(un)?prepare_complete$/ && payload ~ /^(bi_tcxo(_ao)?|tcsr_.*)$/) {
			known[payload]=1; prepared[payload]=(event == "clk_prepare_complete")
		}
		if (window && event == "rpmh_send_msg" && payload ~ /^apps_rsc:/ &&
		    match(payload, /\[(sleep|wake)\].*addr: 0x0*300e0 data: (0x[0-9a-f]+|0)( |$)/, request)) {
			if (request[1] == "sleep") { sleep_value=strtonum(request[2]); sleep_seen=1; wake_seen=0 }
			else if (sleep_seen) wake_seen=1
		}
		next
	}
	FILENAME == ARGV[3] {
		if (/PM: suspend entry \(deep\)/) { journal_cycles++; journal_entry=1 }
		if (journal_entry && match($0, /psci: CPU([0-9]+) killed/, cpu) && last_cpu != "" && cpu[1] == last_cpu) {
			cpu_off=1; journal_off++
		}
		if (/Enabling non-boot CPUs/) {
			if (cpu_off) journal_on++
			cpu_off=0; journal_entry=0
		}
		if (/PM: suspend exit/) { cpu_off=0; journal_entry=0 }
		if (cpu_off && match($0, /skipping RPMH req: a:0x0*300e0 s:(0x[0-9a-f]+|0) w:(0x[0-9a-f]+|0)/, cached)) {
			new_sleep=strtonum(cached[1]); new_wake=strtonum(cached[2])
			if (cache_seen && (new_sleep != cached_sleep || new_wake != cached_wake)) cache_conflict=1
			cache_seen=1; cached_sleep=new_sleep; cached_wake=new_wake
		}
	}
	END {
		valid=(loss == "0" && begins == 1 && ends == 1 && start > 0 && finish >= start)
		for (phase_index=1; phase_index<=2; phase_index++) {
			phase=(phase_index == 1 ? "pre" : "post")
			if (counters[phase,"success:"] !~ /^[0-9]+$/ || counters[phase,"fail:"] !~ /^[0-9]+$/) invalid_counters=1
		}
		if (invalid_counters || counters["post","success:"]-counters["pre","success:"] != 1 ||
		    counters["post","fail:"]-counters["pre","fail:"] != 0) valid=0
		verdict="UNKNOWN"; detail="incomplete/lost trace, unsupported suspend path, or unverified suspend outcome"
		if (valid) {
			cache_valid=(journal_cycles == 1 && journal_off == 1 && journal_on == 1 && !cache_conflict &&
				cache_seen && cached_sleep == cached_wake && cached_sleep != 4294967295)
			detail="no complete final XO pair or unambiguous last-CPU-off/on cache record"
			if (sleep_seen && wake_seen && (!cache_seen || (cache_valid && cached_sleep == sleep_value))) {
				verdict=(sleep_value == 0 ? "ZERO" : "NONZERO"); detail=sprintf("programmed sleep request=0x%x", sleep_value)
			} else if (cache_valid && !sleep_seen) {
				verdict=(cached_sleep == 0 ? "ZERO" : "NONZERO")
				detail=sprintf("equal cached sleep/wake request=0x%x; last-CPU-off/on interval, includes early resume", cached_sleep)
			}
		}
		printf "XO_SLEEP_REQUEST: %s (%s)\n", verdict, detail
		printf "XO clock prepare state at entry: %s\n", !valid || !known["bi_tcxo"] ? "UNKNOWN" : (prepared["bi_tcxo"] ? "PREPARED" : "UNPREPARED")
		for (clock in known) if (clock ~ /^tcsr_/) {
			tcsr_count++; if (!known[clock]) tcsr_unknown=1
			if (prepared[clock]) { tcsr_prepared++; names=names " " clock }
		}
		printf "TCSR_OUTPUTS_AT_ENTRY: %s%s\n", !valid || !tcsr_count || tcsr_unknown ? "UNKNOWN" :
			(tcsr_prepared ? "PREPARED" : "ALL_UNPREPARED"), valid && tcsr_prepared ? names : ""
		print "Entry clock states are reconstructed CCF software states, not in-sleep readback."
		print "APPS request evidence does not prove flush completion, global XO level, or an isolated syscon reference fix."
	}' "$log" "$trace" "$kernel_log"
}

