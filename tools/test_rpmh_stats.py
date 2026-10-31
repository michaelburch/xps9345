import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("xps-rpmh-stats.sh")
SOURCE = SCRIPT.read_text()
OPTIONS = SOURCE.split('TAG="rpmh"', 1)[1].split('KREL="$(uname -r)"', 1)[0]
OPTIONS = 'TAG="rpmh"' + OPTIONS
WAIT = SOURCE.split("# ---- suspend request ----", 1)[1].split(
    "# ---- post snapshot ----", 1
)[0]
TRAPS = SOURCE.split("trap capture_cleanup EXIT", 1)[1].split(
    "if ! capture_start", 1
)[0]
TRAPS = "trap capture_cleanup EXIT" + TRAPS
POST = SOURCE.split("# ---- post snapshot ----", 1)[1].split(
    'capture_stop >> "$OUT"', 1
)[0]
SMP2P_FUNCTIONS = "declare -A SMP2P_REMOTES=()" + SOURCE.split(
    "declare -A SMP2P_REMOTES=()", 1
)[1].split("power_capture_start() {", 1)[0]
SMP2P_SETUP = SOURCE[SOURCE.index("if (( SMP2P_WAKE )); then"):
                     SOURCE.index("\n{\n\techo '=== pre-suspend USB wakeup policy ==='")]
SMP2P_POST = SOURCE.split('capture_stop >> "$OUT"\n', 1)[1].split(
    "\n{\n", 1
)[0]


class ManualSuspendTest(unittest.TestCase):
    def test_usb_wake_trace_options(self):
        for args, expected in ((["--stats-only"], 0),
                               (["--usb-wake-trace"], 2),
                               (["--usb-wake-trace", "--stats-only"], 2)):
            with self.subTest(args=args):
                result = subprocess.run(
                    ["bash", "-uc", OPTIONS + '\necho capture=stats-only\n',
                     "test", *args], capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected == 0:
                    self.assertIn("capture=stats-only", result.stdout)
                else:
                    self.assertIn("has been removed", result.stderr)

    def test_standalone_has_no_trace_setup(self):
        self.assertNotRegex(SOURCE, r"(?m)^\s*(?:source|\.)\s+")
        self.assertNotIn("xo_", SOURCE)
        self.assertNotIn("XO_", SOURCE)
        self.assertNotIn("/sys/kernel/tracing", SOURCE)
        self.assertNotIn("dynamic_debug/control", SOURCE)
        self.assertNotIn("clk_summary", SOURCE)

    def test_standalone_lock_and_restore(self):
        functions = SOURCE.split("suspend_snapshot() {", 1)[1].split(
            "# Subsystems we care about.", 1)[0]
        functions = "suspend_snapshot() {" + functions
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name, state in (("one", "enabled"), ("two", "disabled")):
                (root / name / "power").mkdir(parents=True)
                (root / name / "power/wakeup").write_text(state + "\n")
            harness = r'''
set -eu
USB_ROOT=$1
USB_CONTROLLERS=(one two)
USB_CHANGED=()
USB_RESTORE_FAILED=0
CAPTURE_STOPPED=0
LOCK_FILE=$1/lock
declare -A USB_SAVED=()
'''
            checks = r'''
capture_start
if flock -n "$LOCK_FILE" true; then exit 90; fi
usb_wakeup_disable
test "$(cat "$USB_ROOT/one/power/wakeup")" = disabled
test "$(cat "$USB_ROOT/two/power/wakeup")" = disabled
capture_stop
test "$(cat "$USB_ROOT/one/power/wakeup")" = enabled
test "$(cat "$USB_ROOT/two/power/wakeup")" = disabled
capture_stop
flock -n "$LOCK_FILE" true
'''
            subprocess.run(["bash", "-c", harness + functions + checks,
                            "test", directory], check=True, capture_output=True, text=True)

    def test_partial_usb_override_restores_on_exit(self):
        functions = "suspend_snapshot() {" + SOURCE.split("suspend_snapshot() {", 1)[1].split(
            "# Subsystems we care about.", 1)[0]
        functions = functions.replace("usb_wakeup_write() {", "real_usb_wakeup_write() {", 1)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name in ("one", "two"):
                (root / name / "power").mkdir(parents=True)
                (root / name / "power/wakeup").write_text("enabled\n")
            harness = r'''
set -eu
USB_ROOT=$1
USB_CONTROLLERS=(one two)
USB_CHANGED=()
USB_RESTORE_FAILED=0
CAPTURE_STOPPED=0
LOCK_FILE=$1/lock
declare -A USB_SAVED=()
'''
            checks = r'''
usb_wakeup_write() {
    if [[ $1 == "$USB_ROOT/two/power/wakeup" && $2 == disabled ]]; then return 1; fi
    real_usb_wakeup_write "$@"
}
capture_start
trap capture_stop EXIT
if usb_wakeup_disable; then exit 90; fi
test "$(cat "$USB_ROOT/one/power/wakeup")" = disabled
'''
            subprocess.run(["bash", "-c", harness + functions + checks,
                            "test", directory], check=True, capture_output=True, text=True)
            for name in ("one", "two"):
                self.assertEqual((root / name / "power/wakeup").read_text().strip(), "enabled")

    def run_capture(self, options, samples, action="", request_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "success").write_text("2\n")
            (root / "fail").write_text("0\n")
            (root / "events").touch()
            for index, sample in enumerate(samples, 1):
                (root / f"sample-{index}").write_text(
                    " ".join(str(value) for value in sample) + "\n"
                )
            env = os.environ.copy()
            env.update(
                TEST_ROOT=directory, TEST_ACTION=action,
                TEST_REQUEST_STATUS=str(request_status),
            )
            harness = r"""
set -u
SUSPEND_DIR=$TEST_ROOT
OUT=$TEST_ROOT/capture.log
PRE_BOOT=100
PRE_MONO=90
BOOT=$PRE_BOOT
MONO=$PRE_MONO
poll=0
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$TEST_ROOT/events"
    return "$TEST_REQUEST_STATUS"
}
sleep() {
    poll=$((poll + 1))
    echo "poll $poll" >> "$TEST_ROOT/events"
    if [[ $TEST_ACTION == cancel ]]; then
        kill -INT "$$"
    fi
    if ! read -r BOOT MONO success fail < "$TEST_ROOT/sample-$poll"; then
        echo 'Unexpected additional poll' >&2
        exit 99
    fi
    printf '%s\n' "$success" > "$SUSPEND_DIR/success"
    printf '%s\n' "$fail" > "$SUSPEND_DIR/fail"
}
now_boot_s() { printf '%s\n' "$BOOT"; }
now_mono_only_s() { printf '%s\n' "$MONO"; }
read_energy_uwh() { echo 45000000; }
snapshot() { echo "snapshot $1" >> "$TEST_ROOT/events"; }
read_ddr_stats() { echo ddr-fixture; }
read_wakeup_sources() { echo wakeup-fixture; }
read_genpd_cpu_domains() { echo genpd-fixture; }
read_cpuidle_states() { echo cpuidle-fixture; }
capture_stop() { echo cleanup >> "$TEST_ROOT/events"; }
capture_cleanup() { capture_stop; }
"""
            result = subprocess.run(
                ["bash", "-c", harness + TRAPS + OPTIONS + WAIT + POST
                 + '\nprintf "post boot=%s mono=%s\\n" "$POST_BOOT" "$POST_MONO"\n',
                 "test", *options],
                env=env, text=True, capture_output=True, timeout=5,
            )
            return result, (root / "events").read_text()

    def test_manual_waits_for_lid_then_captures_after_wake(self):
        result, events = self.run_capture(
            ["lid-test", "--manual", "--stats-only", "-s", "300"],
            [(105, 95, 2, 0), (410, 100, 3, 0)],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ready: close the lid", result.stdout)
        self.assertNotIn("systemctl", events)
        self.assertNotIn("SUSPEND in 5 seconds", result.stdout)
        self.assertEqual(events, "poll 1\npoll 2\nsnapshot post\ncleanup\n")
        self.assertIn("post boot=410 mono=100", result.stdout)
        self.assertNotIn("WARNING", result.stdout)

    def test_default_still_requests_suspend_once(self):
        result, events = self.run_capture(
            ["-s", "300"], [(105, 95, 2, 0), (410, 100, 3, 0)]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            events,
            "poll 1\nsystemctl suspend --no-block\npoll 2\nsnapshot post\ncleanup\n",
        )
        self.assertIn("SUSPEND in 5 seconds", result.stdout)

    def test_short_sleep_does_not_wait_for_target_duration(self):
        result, events = self.run_capture(
            ["--manual", "-s", "300"], [(107, 95, 3, 0)]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("woke after 2s suspended, requested 300s", result.stdout)
        self.assertIn("snapshot post", events)
        self.assertNotIn("poll 2", events)

    def test_failed_attempt_with_no_clock_jump_captures_diagnostics(self):
        result, events = self.run_capture(["--manual"], [(105, 95, 2, 1)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING: suspend failed", result.stdout)
        self.assertIn("snapshot post", events)

    def test_stable_clock_jump_still_detects_resume(self):
        result, events = self.run_capture(
            ["--manual", "-s", "300"], [(405, 95, 2, 0), (410, 100, 2, 0)]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, "poll 1\npoll 2\nsnapshot post\ncleanup\n")

    def test_long_sleep_does_not_exhaust_awake_deadline(self):
        result, events = self.run_capture(["--manual"], [(10905, 95, 3, 0)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("snapshot post", events)
        self.assertNotIn("Timed out", result.stderr)

    def test_timeout_without_sleep_is_failure_and_cleans_up(self):
        result, events = self.run_capture(["--manual"], [(7305, 7295, 2, 0)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Timed out waiting", result.stderr)
        self.assertEqual(events, "poll 1\ncleanup\n")

    def test_cancel_cleans_up_without_suspend_or_post_capture(self):
        result, events = self.run_capture(["--manual"], [], action="cancel")
        self.assertEqual(result.returncode, 130)
        self.assertEqual(events, "poll 1\ncleanup\n")

    def test_suspend_request_failure_cleans_up(self):
        result, events = self.run_capture(
            [], [(105, 95, 2, 0)], request_status=1
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Suspend request failed", result.stdout)
        self.assertEqual(events, "poll 1\nsystemctl suspend --no-block\ncleanup\n")

    def test_unknown_option_is_rejected(self):
        result, events = self.run_capture(["--manul"], [])
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown option", result.stderr)
        self.assertEqual(events, "cleanup\n")


class SuspendMeasurementTest(unittest.TestCase):
    def report(self, extra=""):
        function = "print_suspend_measurement() {" + SOURCE.split(
            "print_suspend_measurement() {", 1
        )[1].split("# energy in uWh", 1)[0]
        fixture = r"""
set -u
PRE_BOOT=1084.523898753
PRE_MONO=894.144469428
POST_BOOT=1291.372659056
POST_MONO=904.517682291
PRE_E=45250000
POST_E=45140000
TICK_HZ=19200000
POWER=0
declare -A SNAP=(
    [delta_aosd_count]=40 [delta_aosd_dur]=3579987696
    [delta_cxsd_count]=40 [delta_cxsd_dur]=3581138455
    [delta_ddr_count]=40 [delta_ddr_dur]=3581827710
)
"""
        return subprocess.run(
            ["bash", "-c", fixture + function + extra + "\nprint_suspend_measurement"],
            text=True, capture_output=True, check=True,
        ).stdout

    def test_retained_capture_uses_suspended_denominator(self):
        result = self.report()
        self.assertIn("SUSPEND_TIME: 196.476 s", result)
        self.assertIn("AWAKE_OVERHEAD: 10.373 s", result)
        self.assertIn("AOSD_RESIDENCY: 186.458 s / suspended = 94.901%", result)
        self.assertIn("CXSD_RESIDENCY: 186.518 s / suspended = 94.932%", result)
        self.assertIn("DDR_RESIDENCY: 186.554 s / suspended = 94.950%", result)
        self.assertIn("110000 uWh / 206.849 s = 1.914 W", result)
        self.assertIn("SUSPEND_POWER: 1.914 W (110000 uWh / 206.849 s; battery window", result)

    def test_zero_suspend_does_not_divide_by_zero(self):
        result = self.report("POST_BOOT=$PRE_BOOT; POST_MONO=$PRE_MONO")
        self.assertIn("/ suspended = NOT_MEASURED", result)
        self.assertIn("BATTERY_WINDOW: INVALID", result)
        self.assertIn("SUSPEND_POWER: INVALID", result)

    def test_missing_energy_without_hook_is_not_measured(self):
        result = self.report("PRE_E=")
        self.assertIn("SUSPEND_POWER: NOT_MEASURED (missing energy sample)", result)

    def test_missing_and_decreased_counters_are_explicit(self):
        result = self.report(
            "unset 'SNAP[delta_aosd_dur]'; SNAP[delta_ddr_dur]=-1; PRE_E="
        )
        self.assertIn("AOSD_RESIDENCY: NOT_MEASURED", result)
        self.assertIn("DDR_RESIDENCY: INVALID", result)
        self.assertIn("BATTERY_WINDOW: NOT_MEASURED", result)


class Smp2pWakeTest(unittest.TestCase):
    def run_policy(self, options=("--smp2p-wake",), mode="", fail_at=0,
                   state="attached", initial=("enabled", "disabled")):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            files = {
                "rproc/remoteproc7/name": "adsp",
                "rproc/remoteproc2/name": "cdsp",
                "rproc/remoteproc0/name": "modem",
                "rproc/remoteproc7/state": state,
                "rproc/remoteproc2/state": "running",
                "rproc/remoteproc7/recovery": initial[0],
                "rproc/remoteproc2/recovery": initial[0],
                "rproc/remoteproc0/recovery": "enabled",
                "platform/smp2p-adsp/power/wakeup": initial[1],
                "platform/smp2p-cdsp/power/wakeup": initial[1],
                "success": "0",
                "fail": "0",
            }
            for name, value in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value + "\n")
            if mode == "missing-wakeup":
                (root / "platform/smp2p-cdsp/power/wakeup").unlink()
            elif mode == "missing-recovery":
                (root / "rproc/remoteproc2/recovery").unlink()
            elif mode == "missing-dsp":
                (root / "rproc/remoteproc2/name").write_text("other\n")
            elif mode == "duplicate-dsp":
                (root / "rproc/remoteproc0/name").write_text("adsp\n")

            env = os.environ.copy()
            env.update(TEST_ROOT=str(root), TEST_MODE=mode, TEST_FAIL_AT=str(fail_at))
            fixture = r"""
set -u
SMP2P_RPROC_DIR=$TEST_ROOT/rproc
SMP2P_PLATFORM_DIR=$TEST_ROOT/platform
SUSPEND_DIR=$TEST_ROOT
OUT=$TEST_ROOT/capture.log
touch "$OUT"
PRE_BOOT=100
PRE_MONO=90
BOOT=100
MONO=90
writes=0
poll=0
"""
            # Keep actual writes/readback, but log and inject failures at the
            # sysfs boundary. Every path is inside the temporary fixture.
            functions = SMP2P_FUNCTIONS.replace(
                "smp2p_write_verify() {", "actual_write_verify() {", 1
            )
            mocks = r"""
smp2p_write_verify() {
    writes=$((writes + 1))
    echo "write ${1#"$TEST_ROOT"/}=$2" >> "$TEST_ROOT/events"
    if [[ $2 == enabled ]]; then
        for path in "$SMP2P_RPROC_DIR"/remoteproc{2,7}/recovery; do
            [[ $(command cat "$path") == disabled ]] || exit 98
        done
    fi
    actual_write_verify "$@"
}
printf() {
    if [[ $TEST_MODE == write-failure && $writes == "$TEST_FAIL_AT" &&
          $1 == '%s\n' ]]; then
        return 1
    fi
    builtin printf "$@"
}
cat() {
    if [[ $TEST_MODE == readback-failure && $writes == "$TEST_FAIL_AT" &&
          ( $1 == */recovery || $1 == */wakeup ) ]]; then
        echo unexpected
        return
    fi
    command cat "$@"
}
systemctl() {
    echo "systemctl $*" >> "$TEST_ROOT/events"
    [[ $TEST_MODE != request-failure ]]
}
sleep() {
    poll=$((poll + 1))
    if [[ $TEST_MODE == cancel ]]; then kill -INT "$$"; fi
    if (( ! MANUAL && poll == 1 )); then
        if [[ $TEST_MODE == before-request-change ]]; then
            echo disabled > "$SMP2P_PLATFORM_DIR/smp2p-adsp/power/wakeup"
        fi
        return
    fi
    BOOT=705
    MONO=95
    echo 1 > "$SUSPEND_DIR/success"
    if [[ $TEST_MODE == post-change ]]; then
        echo enabled > "$SMP2P_RPROC_DIR/remoteproc2/recovery"
    elif [[ $TEST_MODE == post-crash ]]; then
        echo crashed > "$SMP2P_RPROC_DIR/remoteproc7/state"
    fi
}
now_boot_s() { echo "$BOOT"; }
now_mono_only_s() { echo "$MONO"; }
read_energy_uwh() { echo 45000000; }
snapshot() { echo "snapshot $1" >> "$TEST_ROOT/events"; }
read_ddr_stats() { :; }
read_wakeup_sources() { :; }
read_genpd_cpu_domains() { :; }
read_cpuidle_states() { :; }
capture_cleanup() { echo cleanup >> "$TEST_ROOT/events"; }
"""
            result = subprocess.run(
                ["bash", "-c", fixture + functions + mocks + TRAPS + OPTIONS
                 + SMP2P_SETUP + WAIT + POST + SMP2P_POST
                 + '\n(( SMP2P_VERIFY_FAILED == 0 )) || exit 1\n',
                 "test", *options],
                env=env, text=True, capture_output=True, timeout=5,
            )
            policies = {
                name: (root / name).read_text().strip()
                for name in files
                if name.endswith(("/recovery", "/wakeup")) and (root / name).exists()
            }
            return (
                result, (root / "events").read_text(),
                (root / "capture.log").read_text(), policies,
            )

    def test_default_does_not_touch_policy(self):
        result, events, log, policies = self.run_policy(options=())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("write ", events)
        self.assertNotIn("SMP2P", log)
        self.assertEqual(policies["rproc/remoteproc7/recovery"], "enabled")
        self.assertEqual(policies["platform/smp2p-adsp/power/wakeup"], "disabled")

    def test_name_mapping_order_readback_and_persistence(self):
        for manual in (False, True):
            with self.subTest(manual=manual):
                options = ["--smp2p-wake", "--stats-only"]
                if manual:
                    options.append("--manual")
                result, events, log, policies = self.run_policy(options=options)
                self.assertEqual(result.returncode, 0, result.stderr)
                writes = [line for line in events.splitlines() if line.startswith("write ")]
                self.assertEqual(writes, [
                    "write rproc/remoteproc7/recovery=disabled",
                    "write rproc/remoteproc2/recovery=disabled",
                    "write platform/smp2p-adsp/power/wakeup=enabled",
                    "write platform/smp2p-cdsp/power/wakeup=enabled",
                ])
                self.assertEqual("systemctl suspend --no-block" in events, not manual)
                self.assertIn("=== pre-suspend SMP2P", log)
                self.assertIn("=== post-resume SMP2P", log)
                self.assertIn("name=adsp state=attached recovery=disabled wakeup=enabled", log)
                self.assertIn("name=cdsp state=running recovery=disabled wakeup=enabled", log)
                self.assertIn("persist until reboot", result.stdout)
                self.assertEqual(policies["rproc/remoteproc0/recovery"], "enabled")
                self.assertEqual(policies["rproc/remoteproc7/recovery"], "disabled")
                self.assertEqual(policies["platform/smp2p-adsp/power/wakeup"], "enabled")

    def test_already_configured_policy_is_supported(self):
        result, _, log, _ = self.run_policy(initial=("disabled", "enabled"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recovery=disabled wakeup=enabled", log)

    def test_preflight_errors_do_not_write_or_suspend(self):
        for mode in ("missing-wakeup", "missing-recovery", "missing-dsp", "duplicate-dsp"):
            with self.subTest(mode=mode):
                result, events, log, _ = self.run_policy(mode=mode)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(events, "cleanup\n")
                self.assertIn("SMP2P setup failed; suspend not started", result.stderr)
                self.assertRegex(log, "unavailable|Missing|Ambiguous")
        for state in ("crashed", "offline", "detached"):
            with self.subTest(state=state):
                result, events, log, _ = self.run_policy(state=state)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(events, "cleanup\n")
                self.assertIn("cold boot before testing", log)
        for initial in (("recover", "disabled"), ("enabled", "unknown")):
            with self.subTest(initial=initial):
                result, events, log, _ = self.run_policy(initial=initial)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(events, "cleanup\n")
                self.assertIn("Invalid adsp recovery or wakeup policy", log)

    def test_each_write_or_readback_failure_aborts(self):
        for mode in ("write-failure", "readback-failure"):
            for fail_at in range(1, 5):
                with self.subTest(mode=mode, fail_at=fail_at):
                    result, events, log, _ = self.run_policy(mode=mode, fail_at=fail_at)
                    self.assertEqual(result.returncode, 1)
                    self.assertNotIn("systemctl", events)
                    self.assertNotIn("snapshot post", events)
                    self.assertEqual(events.count("write "), fail_at)
                    self.assertRegex(log, "Failed to write|readback mismatch")
                    self.assertIn("not restored", result.stderr)

    def test_policy_change_during_countdown_blocks_suspend(self):
        result, events, log, _ = self.run_policy(mode="before-request-change")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("systemctl", events)
        self.assertIn("=== pre-request SMP2P", log)
        self.assertIn("SMP2P verification failed", result.stderr)

    def test_post_resume_mismatch_keeps_capture_but_fails(self):
        for mode in ("post-change", "post-crash"):
            with self.subTest(mode=mode):
                result, events, log, _ = self.run_policy(mode=mode)
                self.assertEqual(result.returncode, 1)
                self.assertIn("snapshot post", events)
                self.assertIn("SMP2P post-resume verification failed; capture retained", result.stderr)
                self.assertIn("SMP2P verification failed", log)

    def test_cancel_or_suspend_error_does_not_restore_recovery(self):
        for mode, expected in (("cancel", 130), ("request-failure", 1)):
            with self.subTest(mode=mode):
                result, events, _, policies = self.run_policy(mode=mode)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn("cleanup", events)
                self.assertEqual(policies["rproc/remoteproc7/recovery"], "disabled")
                self.assertEqual(policies["rproc/remoteproc2/recovery"], "disabled")
                self.assertEqual(policies["platform/smp2p-adsp/power/wakeup"], "enabled")
                self.assertEqual(policies["platform/smp2p-cdsp/power/wakeup"], "enabled")


class PowerCaptureTest(unittest.TestCase):
    FUNCTIONS = "power_capture_start() {" + SOURCE.split(
        "power_capture_start() {", 1
    )[1].split("print_suspend_measurement() {", 1)[0]

    def run_power(self, pre="1000000 100 90 Discharging",
                  post="900000 1900 92 Discharging", error=""):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "pre").write_text(pre + "\n")
            (root / "post").write_text(post + "\n")
            (root / "error.log").write_text(error)
            env = os.environ.copy()
            env["POWER_DIR"] = directory
            return subprocess.run(
                ["bash", "-uc", self.FUNCTIONS + "\npower_capture_report"],
                env=env, text=True, capture_output=True, timeout=5,
            )

    def test_energy_delta_over_boundary_elapsed_time(self):
        result = self.run_power()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SUSPEND_POWER: 0.200 W (100000 uWh / 1800.000 s", result.stdout)
        self.assertIn("suspended=1798.000 s; entry/resume=2.000 s", result.stdout)

    def test_charging_or_failed_samples_are_invalid(self):
        for options in (
            {"post": "900000 1900 92 Charging"},
            {"error": "battery read failed"},
            {"post": "1000000 1900 92 Discharging"},
            {"post": "900000 102 92 Discharging"},
        ):
            with self.subTest(options=options):
                result = self.run_power(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SUSPEND_POWER: INVALID", result.stdout)

    def test_temporary_hook_lifecycle_and_actual_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            hooks = root / "hooks"
            hooks.mkdir()
            functions = self.FUNCTIONS.replace(
                "/usr/lib/systemd/system-sleep", str(hooks)
            )
            harness = r"""
set -eu
OUT="$TEST_ROOT/stats.log"
POWER_HOOK=
POWER_DIR=
capture_stop() { echo stopped; }
power_capture_start
test -x "$POWER_HOOK"
# Mock only the sampler process, not hook generation or report calculations.
python3() {
    case "$2" in
        pre) echo '1000000 100 90 Discharging' ;;
        post) echo '900000 1900 92 Discharging' ;;
        *) return 1 ;;
    esac
}
export -f python3
"$POWER_HOOK" pre suspend
"$POWER_HOOK" post suspend
power_capture_report
saved_hook=$POWER_HOOK
capture_cleanup
test ! -e "$saved_hook"
test -f "$POWER_DIR/pre"
test -f "$POWER_DIR/post"
capture_cleanup
"""
            env = os.environ.copy()
            env["TEST_ROOT"] = directory
            result = subprocess.run(
                ["bash", "-c", functions + harness], env=env,
                text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("SUSPEND_POWER: 0.200 W", result.stdout)
            self.assertEqual(list(hooks.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
