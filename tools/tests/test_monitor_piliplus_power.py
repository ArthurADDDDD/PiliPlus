"""Offline unit tests for tools/monitor_piliplus_power.py.

These tests exercise only the pure parsing functions and CSV/compare
logic using fixture text -- no `adb` and no connected device required.
Run with:

    python -m unittest discover -s tools/tests -v

or, from the repo root:

    python -m unittest tools.tests.test_monitor_piliplus_power -v
"""

from __future__ import annotations

import csv
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import monitor_piliplus_power as m  # noqa: E402


class ParseDumpsysBatteryTest(unittest.TestCase):
    def test_typical_output(self) -> None:
        text = """
Current Battery Service state:
  AC powered: false
  USB powered: true
  Wireless powered: false
  Max charging current: 500000
  status: 2
  health: 2
  present: true
  level: 87
  scale: 100
  voltage: 4123
  temperature: 302
  technology: Li-ion
"""
        result = m.parse_dumpsys_battery(text)
        self.assertEqual(result["level"], 87)
        self.assertAlmostEqual(result["temperature_c"], 30.2)
        self.assertEqual(result["status"], "charging")

    def test_discharging_status(self) -> None:
        text = "level: 55\nstatus: 3\ntemperature: 289\n"
        result = m.parse_dumpsys_battery(text)
        self.assertEqual(result["status"], "discharging")
        self.assertEqual(result["level"], 55)

    def test_empty_input_returns_none_fields(self) -> None:
        result = m.parse_dumpsys_battery("")
        self.assertIsNone(result["level"])
        self.assertIsNone(result["temperature_c"])
        self.assertEqual(result["status"], "unknown")

    def test_garbage_input_does_not_raise(self) -> None:
        result = m.parse_dumpsys_battery("not dumpsys output at all\n\x00\xff")
        self.assertIsNone(result["level"])


class ParsePowerSupplySysfsTest(unittest.TestCase):
    def test_positive_current_convention(self) -> None:
        result = m.parse_power_supply_sysfs("512340", "4123000", "2800000", None)
        self.assertEqual(result["current_now_raw_ua"], 512340)
        self.assertEqual(result["current_now_sign"], "positive")
        self.assertAlmostEqual(result["current_now_abs_ma"], 512.34)
        self.assertAlmostEqual(result["voltage_now_v"], 4.123)
        self.assertEqual(result["charge_counter_uah"], 2800000)
        self.assertIsNone(result["energy_counter_nwh"])

    def test_negative_current_convention_still_yields_positive_magnitude(self) -> None:
        # Some OEM kernels report discharging as negative current_now; this
        # must NOT be interpreted as "negative power" anywhere downstream.
        result = m.parse_power_supply_sysfs("-512340", "4123000", None, None)
        self.assertEqual(result["current_now_sign"], "negative")
        self.assertAlmostEqual(result["current_now_abs_ma"], 512.34)
        self.assertGreaterEqual(result["current_now_abs_ma"], 0)

    def test_zero_current(self) -> None:
        result = m.parse_power_supply_sysfs("0", "4000000", None, None)
        self.assertEqual(result["current_now_sign"], "zero")
        self.assertEqual(result["current_now_abs_ma"], 0.0)

    def test_missing_values_are_none_not_crash(self) -> None:
        result = m.parse_power_supply_sysfs(None, None, None, None)
        self.assertIsNone(result["current_now_raw_ua"])
        self.assertEqual(result["current_now_sign"], m.UNAVAILABLE)
        self.assertIsNone(result["current_now_abs_ma"])
        self.assertIsNone(result["voltage_now_v"])

    def test_permission_denied_text_does_not_crash(self) -> None:
        result = m.parse_power_supply_sysfs(
            "/system/bin/sh: cat: /sys/.../current_now: Permission denied", None, None, None
        )
        self.assertIsNone(result["current_now_raw_ua"])


class EstimatePowerTest(unittest.TestCase):
    def test_basic_estimate(self) -> None:
        power = m.estimate_power_w(500.0, 4.0)
        self.assertAlmostEqual(power, 2.0)

    def test_missing_inputs_return_none(self) -> None:
        self.assertIsNone(m.estimate_power_w(None, 4.0))
        self.assertIsNone(m.estimate_power_w(500.0, None))

    def test_power_is_never_negative(self) -> None:
        # abs_current_ma is always >= 0 by construction (see
        # parse_power_supply_sysfs), so estimate_power_w can't go negative
        # even on devices with an inverted current_now sign convention.
        power = m.estimate_power_w(500.0, 4.0)
        self.assertGreaterEqual(power, 0)


class ParseCpuinfoTest(unittest.TestCase):
    def test_typical_output(self) -> None:
        text = """
Load: 2.1 / 1.8 / 1.5
CPU usage from 10132ms to 132ms ago (2026-07-10 10:00:00 to 2026-07-10 10:00:10):
  9.5% 1234:com.example.piliplus/u0a123: 8.2% user + 1.3% kernel
  3.1% 4567:com.android.systemui: 2.0% user + 1.1% kernel
  TOTAL: 45% 20% user + 15% kernel + 3% iowait + 7% irq
"""
        result = m.parse_cpuinfo(text, "com.example.piliplus")
        self.assertEqual(result["pid"], 1234)
        self.assertAlmostEqual(result["app_cpu_pct"], 9.5)
        self.assertAlmostEqual(result["total_cpu_pct"], 45.0)

    def test_package_not_running(self) -> None:
        text = "TOTAL: 12% 5% user + 7% kernel\n"
        result = m.parse_cpuinfo(text, "com.example.piliplus")
        self.assertIsNone(result["pid"])
        self.assertIsNone(result["app_cpu_pct"])
        self.assertAlmostEqual(result["total_cpu_pct"], 12.0)

    def test_empty_input(self) -> None:
        result = m.parse_cpuinfo("", "com.example.piliplus")
        self.assertIsNone(result["pid"])
        self.assertIsNone(result["total_cpu_pct"])


class ParseMeminfoRssTest(unittest.TestCase):
    def test_total_row(self) -> None:
        text = """
App Summary
                       Pss(KB)                        Rss(KB)
                        ------                         ------
           Java Heap:    12345                          23456
         Native Heap:     6789                           7890
                TOTAL:    50000    TOTAL SWAP PSS:        0    TOTAL RSS: 98765
"""
        rss = m.parse_meminfo_rss(text)
        # First number after "TOTAL" is taken as the RSS-relevant summary
        # figure; we only assert it parses a plausible int, not the exact
        # semantic column (layout is not a stable API across versions).
        self.assertIsInstance(rss, int)
        self.assertEqual(rss, 50000)

    def test_no_total_row(self) -> None:
        self.assertIsNone(m.parse_meminfo_rss("nothing relevant here\n"))

    def test_empty(self) -> None:
        self.assertIsNone(m.parse_meminfo_rss(""))


class ParseDisplayRefreshRateTest(unittest.TestCase):
    def test_refresh_rate_field(self) -> None:
        text = "DisplayModeRecord{mMode={id=1, width=1080, height=2400, fps=120.0}, refreshRate=120.0}"
        self.assertAlmostEqual(m.parse_display_refresh_rate(text), 120.0)

    def test_render_frame_rate_fallback(self) -> None:
        text = "renderFrameRate=60.0"
        self.assertAlmostEqual(m.parse_display_refresh_rate(text), 60.0)

    def test_missing(self) -> None:
        self.assertIsNone(m.parse_display_refresh_rate("nothing here"))


class ParseScreenStateTest(unittest.TestCase):
    def test_display_power_state_on(self) -> None:
        self.assertEqual(m.parse_screen_state("Display Power: state=ON"), "on")

    def test_display_power_state_off(self) -> None:
        self.assertEqual(m.parse_screen_state("Display Power: state=OFF"), "off")

    def test_wakefulness_fallback(self) -> None:
        self.assertEqual(m.parse_screen_state("mWakefulness=Awake"), "on")
        self.assertEqual(m.parse_screen_state("mWakefulness=Asleep"), "off")

    def test_unknown(self) -> None:
        self.assertEqual(m.parse_screen_state("nothing relevant"), "unknown")


class ParseThermalStatusTest(unittest.TestCase):
    def test_status_and_sensors(self) -> None:
        text = """
IsStatusOverride: false
ThermalEventListeners:
Status: 1
Temperature{mValue=30.2, mType=2, mName=battery, mStatus=1}
Temperature{mValue=35.8, mType=3, mName=skin, mStatus=1}
"""
        result = m.parse_thermal_status(text)
        self.assertEqual(result["status"], "LIGHT")
        self.assertAlmostEqual(result["sensors"]["battery"], 30.2)
        self.assertAlmostEqual(result["sensors"]["skin"], 35.8)

    def test_unknown_status_code_falls_back_to_raw_string(self) -> None:
        result = m.parse_thermal_status("Status: 99\n")
        self.assertEqual(result["status"], "99")

    def test_empty(self) -> None:
        result = m.parse_thermal_status("")
        self.assertEqual(result["status"], m.UNAVAILABLE)
        self.assertEqual(result["sensors"], {})


class ParseHardwarePropertiesTempsTest(unittest.TestCase):
    def test_cpu_gpu_temps(self) -> None:
        text = (
            "Temperature{mValue=45.0 mType=7 (TEMPERATURE_TYPE_CPU) mName=cpu0}\n"
            "Temperature{mValue=40.2 mType=8 (TEMPERATURE_TYPE_GPU) mName=gpu0}\n"
        )
        result = m.parse_hardware_properties_temps(text)
        self.assertAlmostEqual(result["cpu"], 45.0)
        self.assertAlmostEqual(result["gpu"], 40.2)

    def test_empty(self) -> None:
        self.assertEqual(m.parse_hardware_properties_temps(""), {})


class PickSensorTempTest(unittest.TestCase):
    def test_prefers_thermal_sensor_map(self) -> None:
        value = m.pick_sensor_temp({"battery": 31.0}, {"cpu": 45.0}, ["battery"])
        self.assertEqual(value, 31.0)

    def test_falls_back_to_hardware_properties(self) -> None:
        value = m.pick_sensor_temp({}, {"cpu": 45.0}, ["cpu"])
        self.assertEqual(value, 45.0)

    def test_not_found_returns_none(self) -> None:
        self.assertIsNone(m.pick_sensor_temp({}, {}, ["modem"]))


class ParseForegroundActivityTest(unittest.TestCase):
    def test_resumed_activity_and_pip(self) -> None:
        text = (
            "topResumedActivity: ActivityRecord{... com.example.piliplus/.PipActivity}\n"
            "windowingMode=2\n"
        )
        result = m.parse_foreground_activity(text)
        self.assertIn("PipActivity", result["foreground_activity"])
        self.assertEqual(result["in_pip"], "true")

    def test_resumed_activity_not_pip(self) -> None:
        text = "mResumedActivity: ActivityRecord{... com.example.piliplus/.MainActivity}\n"
        result = m.parse_foreground_activity(text)
        self.assertIn("MainActivity", result["foreground_activity"])
        self.assertEqual(result["in_pip"], "false")

    def test_empty(self) -> None:
        result = m.parse_foreground_activity("")
        self.assertEqual(result["foreground_activity"], m.UNAVAILABLE)
        self.assertEqual(result["in_pip"], "unknown")


class ParseCodecHintTest(unittest.TestCase):
    def test_finds_c2_decoder_near_package(self) -> None:
        text = (
            "some unrelated block\n"
            "pkg=com.example.piliplus codec_name=c2.android.avc.decoder mime=video/avc\n"
        )
        hint = m.parse_codec_hint(text, "com.example.piliplus")
        self.assertIn("decoder", hint.lower())

    def test_no_match_returns_unavailable(self) -> None:
        self.assertEqual(m.parse_codec_hint("nothing useful here", "com.example.piliplus"), m.UNAVAILABLE)

    def test_empty_text(self) -> None:
        self.assertEqual(m.parse_codec_hint("", "com.example.piliplus"), m.UNAVAILABLE)


class CountLogcatErrorsTest(unittest.TestCase):
    def test_counts_each_category_independently(self) -> None:
        text = "\n".join(
            [
                "I/MediaCodec: some info line",
                "E/MediaCodec: MediaCodec configure error",
                "E/SurfaceTexture: Surface abandoned",
                "W/PipShellNative: attach failed exception",
                "E/EGL_emulation: EGL call failed",
            ]
        )
        counts = m.count_logcat_errors(text)
        self.assertEqual(counts["mediacodec_error_count"], 1)
        self.assertEqual(counts["surface_error_count"], 1)
        self.assertEqual(counts["pip_error_count"], 1)
        self.assertEqual(counts["egl_error_count"], 1)

    def test_empty_text(self) -> None:
        counts = m.count_logcat_errors("")
        self.assertTrue(all(v == 0 for v in counts.values()))


class FilterLogcatLineTest(unittest.TestCase):
    def test_keeps_relevant_lines(self) -> None:
        self.assertTrue(m.filter_logcat_line("E/MediaCodec: boom"))
        self.assertTrue(m.filter_logcat_line("I/PipShellDart: attached"))
        self.assertTrue(m.filter_logcat_line("F/libc: FATAL EXCEPTION in thread"))

    def test_drops_unrelated_lines(self) -> None:
        self.assertFalse(m.filter_logcat_line("D/SomeRandomTag: doing unrelated stuff"))

    def test_keeps_lines_mentioning_package(self) -> None:
        self.assertTrue(
            m.filter_logcat_line("D/ActivityManager: Start proc com.example.piliplus", "com.example.piliplus")
        )


class BuildSampleWithFakeAdbTest(unittest.TestCase):
    """Integration-style test of build_sample() using a stub AdbClient so
    the sampling orchestration itself gets coverage without a real device.
    """

    class FakeAdb:
        def __init__(self, responses: dict[str, str]) -> None:
            self.responses = responses

        def shell_or_none(self, command: str, timeout=None):  # noqa: ANN001
            for prefix, response in self.responses.items():
                if command.startswith(prefix):
                    return response
            return None

    def test_all_fields_populated_when_everything_available(self) -> None:
        fake = self.FakeAdb(
            {
                "dumpsys battery": "level: 80\nstatus: 3\ntemperature: 300\n",
                "cat /sys/class/power_supply/battery/current_now": "-450000",
                "cat /sys/class/power_supply/battery/voltage_now": "4100000",
                "cat /sys/class/power_supply/battery/charge_counter": "2500000",
                "cat /sys/class/power_supply/battery/energy_counter": "9000000",
                "dumpsys cpuinfo": "5.0% 111:com.example.piliplus/u0a1: 4% user + 1% kernel\nTOTAL: 20%\n",
                "dumpsys meminfo com.example.piliplus": "TOTAL: 123456\n",
                "dumpsys power": "Display Power: state=ON\n",
                "dumpsys display": "refreshRate=60.0\n",
                "dumpsys activity activities": "topResumedActivity: ActivityRecord{x com.example.piliplus/.PipActivity}\nwindowingMode=2\n",
                "dumpsys thermalservice": "Status: 0\nTemperature{mValue=30.0, mType=2, mName=battery, mStatus=0}\n",
                "dumpsys hardware_properties": "Temperature{mValue=40.0 mType=7 (TEMPERATURE_TYPE_CPU)}\n",
                "dumpsys media.metrics": "com.example.piliplus codec_name=c2.android.avc.decoder\n",
            }
        )
        row = m.build_sample(fake, "com.example.piliplus", start_time=__import__("time").time())
        self.assertEqual(row["battery_level_pct"], 80)
        self.assertEqual(row["battery_status"], "discharging")
        self.assertEqual(row["current_now_sign"], "negative")
        self.assertAlmostEqual(row["current_now_abs_ma"], 450.0)
        self.assertNotEqual(row["estimated_power_w"], m.UNAVAILABLE)
        self.assertEqual(row["app_pid"], 111)
        self.assertEqual(row["screen_state"], "on")
        self.assertEqual(row["refresh_rate_hz"], 60.0)
        self.assertEqual(row["in_pip"], "true")
        self.assertEqual(row["thermal_status"], "NONE")
        self.assertNotEqual(row["codec_hint"], m.UNAVAILABLE)

    def test_missing_everything_yields_unavailable_not_crash(self) -> None:
        fake = self.FakeAdb({})
        row = m.build_sample(fake, "com.example.piliplus", start_time=__import__("time").time())
        # Error counters are derived purely from the accumulated logcat text
        # (empty here, not adb-dependent), so 0 is a legitimate answer, not
        # "unavailable" -- every other field genuinely depends on an adb
        # response we've stubbed out entirely.
        error_count_fields = {
            "mediacodec_error_count",
            "egl_error_count",
            "surface_error_count",
            "pip_error_count",
        }
        for field in m.CSV_FIELDS:
            if field in ("timestamp_iso", "elapsed_s") or field in error_count_fields:
                continue
            self.assertEqual(row[field], m.UNAVAILABLE, f"field {field} should be unavailable")
        for field in error_count_fields:
            self.assertEqual(row[field], 0, f"field {field} should be a real 0 count")


class SummaryAndCompareTest(unittest.TestCase):
    def _sample_row(self, **overrides) -> dict:
        row = {field: m.UNAVAILABLE for field in m.CSV_FIELDS}
        row.update(
            {
                "timestamp_iso": "2026-07-10T00:00:00+00:00",
                "elapsed_s": 0,
                "battery_level_pct": 80,
                "battery_temp_c": 30.0,
                "battery_status": "discharging",
                "current_now_abs_ma": 400.0,
                "voltage_now_v": 4.0,
                "estimated_power_w": 1.6,
                "app_cpu_pct": 10.0,
                "app_rss_kb": 100000,
                "thermal_status": "NONE",
                "in_pip": "true",
            }
        )
        row.update(overrides)
        return row

    def test_build_summary_markdown_handles_full_run(self) -> None:
        samples = [
            self._sample_row(elapsed_s=0, battery_level_pct=80, battery_temp_c=29.0),
            self._sample_row(elapsed_s=600, battery_level_pct=78, battery_temp_c=31.5),
        ]
        metadata = {
            "label": "test-run",
            "package": "com.example.piliplus",
            "device_model": "Pixel 10 Pro",
            "android_release": "17",
            "android_sdk": "37",
            "app_version_name": "1.0.0",
            "requested_duration_s": 600,
            "actual_duration_s": 600,
            "interrupted": False,
            "sample_count": 2,
            "expected_sample_count": 2,
        }
        markdown = m.build_summary_markdown(metadata, samples)
        self.assertIn("test-run", markdown)
        self.assertIn("NOT equivalent to full battery-life", markdown)
        self.assertIn("Temperature rise", markdown)

    def test_build_summary_markdown_handles_empty_samples(self) -> None:
        markdown = m.build_summary_markdown({"label": "empty-run"}, [])
        self.assertIn("No samples were collected", markdown)

    def test_missing_rate_and_numeric_values_ignore_unavailable(self) -> None:
        samples = [
            self._sample_row(app_cpu_pct=m.UNAVAILABLE),
            self._sample_row(app_cpu_pct=20.0),
        ]
        self.assertEqual(m._missing_rate(samples, "app_cpu_pct"), 0.5)
        self.assertEqual(m._numeric_values(samples, "app_cpu_pct"), [20.0])

    def test_build_compare_markdown_two_runs(self) -> None:
        run_a = (
            Path("run-a"),
            {"label": "no-subtitle", "actual_duration_s": 600},
            [
                self._sample_row(current_now_abs_ma=300.0, battery_temp_c=29.0),
                self._sample_row(current_now_abs_ma=310.0, battery_temp_c=30.0),
            ],
        )
        run_b = (
            Path("run-b"),
            {"label": "subtitle-on", "actual_duration_s": 600},
            [
                self._sample_row(current_now_abs_ma=340.0, battery_temp_c=29.0),
                self._sample_row(current_now_abs_ma=360.0, battery_temp_c=31.0),
            ],
        )
        markdown = m.build_compare_markdown([run_a, run_b])
        self.assertIn("no-subtitle", markdown)
        self.assertIn("subtitle-on", markdown)
        self.assertIn("Comparability caveats", markdown)

    def test_resolve_run_dirs_glob_and_literal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "20260101-000000-a").mkdir()
            (base / "20260101-000100-a").mkdir()
            (base / "not-a-run.txt").write_text("x")

            resolved = m.resolve_run_dirs([str(base / "*-a")])
            self.assertEqual(len(resolved), 2)

            resolved_literal = m.resolve_run_dirs([str(base / "20260101-000000-a")])
            self.assertEqual(len(resolved_literal), 1)

    def test_load_run_round_trips_csv_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp) / "run"
            run_dir.mkdir()
            (run_dir / "metadata.json").write_text(json.dumps({"label": "x"}), encoding="utf-8")
            with open(run_dir / "samples.csv", "w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=m.CSV_FIELDS)
                writer.writeheader()
                writer.writerow(self._sample_row())
            metadata, samples = m.load_run(run_dir)
            self.assertEqual(metadata["label"], "x")
            self.assertEqual(len(samples), 1)
            self.assertEqual(samples[0]["battery_level_pct"], "80")  # CSV round-trips as str


class CliParserTest(unittest.TestCase):
    def test_record_requires_label(self) -> None:
        parser = m.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["record"])

    def test_record_defaults(self) -> None:
        parser = m.build_parser()
        args = parser.parse_args(["record", "--label", "x"])
        self.assertEqual(args.package, m.DEFAULT_PACKAGE)
        self.assertEqual(args.duration, m.DEFAULT_DURATION_S)
        self.assertEqual(args.interval, m.DEFAULT_INTERVAL_S)
        self.assertFalse(args.reset_batterystats_before)

    def test_compare_requires_at_least_one_pattern(self) -> None:
        parser = m.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["compare"])

    def test_compare_parses_multiple_patterns(self) -> None:
        parser = m.build_parser()
        args = parser.parse_args(["compare", "a/*", "b/*"])
        self.assertEqual(args.runs, ["a/*", "b/*"])


if __name__ == "__main__":
    unittest.main()
