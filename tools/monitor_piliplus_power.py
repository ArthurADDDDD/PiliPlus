#!/usr/bin/env python3
"""Reusable, no-root power/thermal sampling tool for PiliPlus on Android.

Samples battery/thermal/CPU/memory/display/PiP state at a fixed interval via
``adb shell`` and writes a self-contained report directory. Standard-library
only, so it runs on a bare Python 3.9+ install with no ``pip install``.

This tool never claims to have measured anything by itself: it is only
*run* by a human against a real device. See docs/POWER_TEST_GUIDE.md for a
test matrix designed to separate screen/decode/PiP-composition/subtitle/
danmaku power costs from each other.

Usage
-----
    python tools/monitor_piliplus_power.py record --label pip-subtitle-on \\
        --duration 1200 --interval 10

    python tools/monitor_piliplus_power.py compare \\
        .review/power/*-pip-no-overlay-* .review/power/*-pip-subtitle-on-*

Design notes
------------
- All Android-output parsing is done by small, pure functions (``parse_*``)
  that take already-decoded text and return plain dicts/values. They have
  no dependency on ``subprocess`` or ``adb`` and are covered by offline
  unit tests in ``tools/tests/test_monitor_piliplus_power.py`` -- no device
  needs to be connected to run those tests.
- Every field that can't be read (missing permission, sensor not present,
  older/newer Android layout) is recorded as the literal string
  ``"unavailable"`` rather than raising -- a `record` run should never
  crash because one `dumpsys` field is missing on a particular device.
- Nothing here runs `batterystats --reset`, changes brightness/refresh
  rate, toggles networking, or starts/stops the app by default. The one
  destructive option (`--reset-batterystats-before`) is opt-in and prints
  a warning before running.
"""

from __future__ import annotations

import argparse
import csv
import dataclasses
import glob
import json
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

UNAVAILABLE = "unavailable"
DEFAULT_PACKAGE = "com.example.piliplus"
DEFAULT_OUTPUT_ROOT = Path(".review") / "power"
DEFAULT_INTERVAL_S = 10
DEFAULT_DURATION_S = 1200

# Order matters: this is both the CSV column order and the contract
# `compare` relies on when reading old `samples.csv` files back in.
CSV_FIELDS = [
    "timestamp_iso",
    "elapsed_s",
    "battery_level_pct",
    "battery_temp_c",
    "battery_status",
    "current_now_raw_ua",
    "current_now_sign",
    "current_now_abs_ma",
    "voltage_now_v",
    "charge_counter_uah",
    "energy_counter_nwh",
    "estimated_power_w",
    "app_pid",
    "app_cpu_pct",
    "total_cpu_pct",
    "app_rss_kb",
    "screen_state",
    "refresh_rate_hz",
    "in_pip",
    "foreground_activity",
    "thermal_status",
    "temp_battery_c",
    "temp_skin_c",
    "temp_cpu_c",
    "temp_gpu_c",
    "temp_modem_c",
    "codec_hint",
    "mediacodec_error_count",
    "egl_error_count",
    "surface_error_count",
    "pip_error_count",
]

# Columns that are numeric for statistics purposes in `compare`/SUMMARY.
NUMERIC_FIELDS = {
    "elapsed_s",
    "battery_level_pct",
    "battery_temp_c",
    "current_now_raw_ua",
    "current_now_abs_ma",
    "voltage_now_v",
    "charge_counter_uah",
    "energy_counter_nwh",
    "estimated_power_w",
    "app_pid",
    "app_cpu_pct",
    "total_cpu_pct",
    "app_rss_kb",
    "refresh_rate_hz",
    "temp_battery_c",
    "temp_skin_c",
    "temp_cpu_c",
    "temp_gpu_c",
    "temp_modem_c",
    "mediacodec_error_count",
    "egl_error_count",
    "surface_error_count",
    "pip_error_count",
}

THERMAL_STATUS_NAMES = {
    0: "NONE",
    1: "LIGHT",
    2: "MODERATE",
    3: "SEVERE",
    4: "CRITICAL",
    5: "EMERGENCY",
    6: "SHUTDOWN",
}


# ---------------------------------------------------------------------------
# adb plumbing
# ---------------------------------------------------------------------------


class AdbError(RuntimeError):
    """Raised for adb setup problems (missing binary, 0/2+ devices, ...)."""


@dataclasses.dataclass
class AdbClient:
    adb_path: str = "adb"
    serial: Optional[str] = None
    shell_timeout_s: float = 15.0

    def _base_args(self) -> list[str]:
        args = [self.adb_path]
        if self.serial:
            args += ["-s", self.serial]
        return args

    def ensure_ready(self) -> None:
        """Verify adb exists, and exactly one device is available/selected."""
        resolved = shutil.which(self.adb_path)
        if resolved is None and not Path(self.adb_path).exists():
            raise AdbError(
                f"adb executable not found: {self.adb_path!r}. "
                "Pass --adb <path-to-adb> or add adb to PATH."
            )
        try:
            proc = subprocess.run(
                [self.adb_path, "devices"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=10,
            )
        except FileNotFoundError as exc:
            raise AdbError(f"adb executable not found: {self.adb_path!r}") from exc
        except subprocess.TimeoutExpired as exc:
            raise AdbError("`adb devices` timed out; is adb server stuck?") from exc

        lines = [
            line.strip()
            for line in proc.stdout.splitlines()[1:]
            if line.strip() and "\t" in line
        ]
        devices = [line.split("\t")[0] for line in lines if line.split("\t")[1] == "device"]
        unauthorized = [
            line.split("\t")[0] for line in lines if line.split("\t")[1] != "device"
        ]

        if not devices:
            if unauthorized:
                raise AdbError(
                    "No authorized Android device found. Devices seen but not "
                    f"ready: {unauthorized}. Check the 'Allow USB debugging' "
                    "prompt on the device."
                )
            raise AdbError(
                "No Android device/emulator found via `adb devices`. "
                "Connect Pixel 10 Pro with USB debugging enabled."
            )
        if self.serial is None:
            if len(devices) > 1:
                raise AdbError(
                    f"Multiple devices connected: {devices}. "
                    "Pass --serial <id> to pick one."
                )
            self.serial = devices[0]
        elif self.serial not in devices:
            raise AdbError(
                f"Requested serial {self.serial!r} not in connected devices: {devices}"
            )

    def shell(self, command: str, timeout: Optional[float] = None) -> str:
        """Run `adb shell <command>`, raising AdbError on failure."""
        args = self._base_args() + ["shell", command]
        try:
            proc = subprocess.run(
                args,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout or self.shell_timeout_s,
            )
        except subprocess.TimeoutExpired as exc:
            raise AdbError(f"adb shell timed out: {command!r}") from exc
        except FileNotFoundError as exc:
            raise AdbError(f"adb executable not found: {self.adb_path!r}") from exc
        if proc.returncode != 0 and not proc.stdout:
            raise AdbError(
                f"adb shell failed ({proc.returncode}): {command!r}: {proc.stderr.strip()}"
            )
        return proc.stdout

    def shell_or_none(self, command: str, timeout: Optional[float] = None) -> Optional[str]:
        """Best-effort variant of `shell()` -- returns None instead of raising."""
        try:
            return self.shell(command, timeout=timeout)
        except AdbError:
            return None

    def popen_logcat(self, extra_args: Optional[list[str]] = None) -> subprocess.Popen:
        args = self._base_args() + ["logcat", "-v", "time"] + (extra_args or [])
        return subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )


# ---------------------------------------------------------------------------
# Pure parsing functions (offline-testable, no adb/subprocess dependency)
# ---------------------------------------------------------------------------


def parse_int_or_none(text: Optional[str]) -> Optional[int]:
    if text is None:
        return None
    text = text.strip()
    if not text:
        return None
    match = re.search(r"-?\d+", text)
    if not match:
        return None
    try:
        return int(match.group(0))
    except ValueError:
        return None


def parse_dumpsys_battery(text: str) -> dict[str, Any]:
    """Parse `adb shell dumpsys battery` output.

    Returns level (0-100 int or None), temperature_c (float or None,
    dumpsys reports tenths of a degree C), and status (string, one of
    Android's BatteryManager status names or 'unknown').
    """
    result: dict[str, Any] = {"level": None, "temperature_c": None, "status": "unknown"}
    if not text:
        return result

    level_match = re.search(r"^\s*level:\s*(-?\d+)", text, re.MULTILINE)
    if level_match:
        result["level"] = int(level_match.group(1))

    temp_match = re.search(r"^\s*temperature:\s*(-?\d+)", text, re.MULTILINE)
    if temp_match:
        result["temperature_c"] = int(temp_match.group(1)) / 10.0

    status_match = re.search(r"^\s*status:\s*(\d+)", text, re.MULTILINE)
    if status_match:
        status_names = {
            1: "unknown",
            2: "charging",
            3: "discharging",
            4: "not_charging",
            5: "full",
        }
        result["status"] = status_names.get(int(status_match.group(1)), "unknown")

    return result


def parse_power_supply_sysfs(
    current_now: Optional[str],
    voltage_now: Optional[str],
    charge_counter: Optional[str],
    energy_counter: Optional[str],
) -> dict[str, Any]:
    """Combine raw `cat /sys/class/power_supply/battery/<field>` reads.

    The *sign* of current_now is device/kernel dependent (some report
    negative while discharging, others positive) -- this function never
    tries to infer charge direction from the sign. It only records the
    raw signed value and derives an always-non-negative magnitude in mA
    for power estimation. Charge direction should come from
    `parse_dumpsys_battery()['status']` instead.
    """
    raw_current = parse_int_or_none(current_now)
    raw_voltage = parse_int_or_none(voltage_now)
    raw_charge = parse_int_or_none(charge_counter)
    raw_energy = parse_int_or_none(energy_counter)

    sign = UNAVAILABLE
    abs_current_ma: Optional[float] = None
    if raw_current is not None:
        sign = "positive" if raw_current > 0 else ("negative" if raw_current < 0 else "zero")
        # Values are typically µA; Android has shipped both µA and mA on
        # some OEM kernels historically -- clamp obviously-wrong huge
        # magnitudes isn't attempted here, we just report what the kernel
        # says, scaled assuming µA (the documented/typical unit).
        abs_current_ma = abs(raw_current) / 1000.0

    voltage_v: Optional[float] = None
    if raw_voltage is not None:
        # voltage_now is µV.
        voltage_v = raw_voltage / 1_000_000.0

    return {
        "current_now_raw_ua": raw_current,
        "current_now_sign": sign,
        "current_now_abs_ma": abs_current_ma,
        "voltage_now_v": voltage_v,
        "charge_counter_uah": raw_charge,
        "energy_counter_nwh": raw_energy,
    }


def estimate_power_w(abs_current_ma: Optional[float], voltage_v: Optional[float]) -> Optional[float]:
    """Rough instantaneous power estimate in watts: |I| * V.

    Always non-negative -- this is an estimate of power *magnitude*, not a
    signed charge/discharge power. Returns None if either input is
    unavailable so callers can record "unavailable" instead of a bogus 0.
    """
    if abs_current_ma is None or voltage_v is None:
        return None
    return (abs_current_ma / 1000.0) * voltage_v


def parse_cpuinfo(text: str, package: str) -> dict[str, Any]:
    """Parse `adb shell dumpsys cpuinfo` for app and total CPU usage.

    Example relevant lines:
        9.5% 1234:com.example.piliplus/u0a123: 8.2% user + 1.3% kernel
        TOTAL: 45% 20% user + 15% kernel + 3% iowait + ...
    """
    result: dict[str, Any] = {"pid": None, "app_cpu_pct": None, "total_cpu_pct": None}
    if not text:
        return result

    app_pattern = re.compile(
        r"^\s*([\d.]+)%\s+(\d+):" + re.escape(package) + r"(?:/|\s|$)",
        re.MULTILINE,
    )
    app_match = app_pattern.search(text)
    if app_match:
        result["app_cpu_pct"] = float(app_match.group(1))
        result["pid"] = int(app_match.group(2))

    total_match = re.search(r"^\s*TOTAL:\s*([\d.]+)%", text, re.MULTILINE)
    if total_match:
        result["total_cpu_pct"] = float(total_match.group(1))

    return result


def parse_meminfo_rss(text: str) -> Optional[int]:
    """Parse `adb shell dumpsys meminfo <package>` for TOTAL RSS in kB.

    Looks for a "TOTAL" (or "TOTAL PSS") summary row where the first
    number is the RSS column, matching the standard
    `dumpsys meminfo <pkg>` app-summary table layout.
    """
    if not text:
        return None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("TOTAL"):
            numbers = re.findall(r"\d+", stripped)
            if numbers:
                return int(numbers[0])
    return None


def parse_display_refresh_rate(text: str) -> Optional[float]:
    """Parse `adb shell dumpsys display` for the active refresh rate."""
    if not text:
        return None
    # Common layouts: "refreshRate=120.0" or "renderFrameRate=60.0" or
    # "fps=60.000000" inside the active DisplayModeRecord.
    for pattern in (
        r"refreshRate=([\d.]+)",
        r"renderFrameRate=([\d.]+)",
        r"peakRefreshRate=([\d.]+)",
    ):
        match = re.search(pattern, text)
        if match:
            try:
                return float(match.group(1))
            except ValueError:
                continue
    return None


def parse_screen_state(text: str) -> str:
    """Parse `adb shell dumpsys power` for the display power state."""
    if not text:
        return "unknown"
    match = re.search(r"Display Power:\s*state=(\w+)", text)
    if match:
        return match.group(1).lower()
    match = re.search(r"mWakefulness=(\w+)", text)
    if match:
        awake = match.group(1).lower()
        return "on" if awake == "awake" else "off"
    return "unknown"


def parse_thermal_status(text: str) -> dict[str, Any]:
    """Parse `adb shell dumpsys thermalservice`.

    Returns overall status name and a dict of sensor-name -> temperature
    (float, Celsius) for whatever sensors the device reports. Sensor
    naming/casing varies a lot by OEM; this keeps whatever name Android
    reports rather than trying to normalize it, and callers additionally
    do a best-effort keyword match for battery/skin/cpu/gpu/modem.
    """
    result: dict[str, Any] = {"status": UNAVAILABLE, "sensors": {}}
    if not text:
        return result

    status_match = re.search(r"Status:\s*(\d+)", text)
    if status_match:
        result["status"] = THERMAL_STATUS_NAMES.get(
            int(status_match.group(1)), status_match.group(1)
        )

    # Typical line: "Temperature{mValue=30.2, mType=2, mName=battery, ...}"
    for match in re.finditer(
        r"Temperature\{mValue=(-?[\d.]+),\s*mType=(\d+),\s*mName=([^,}]+)", text
    ):
        value, _type, name = match.groups()
        try:
            result["sensors"][name.strip()] = float(value)
        except ValueError:
            continue

    return result


def parse_hardware_properties_temps(text: str) -> dict[str, float]:
    """Parse `adb shell dumpsys hardware_properties` CPU/GPU temperatures.

    Typical layout has a "Current temperatures:" section with `Temperature{
    ...}` records, e.g. "Temperature{mValue=45.0, mType=7
    (TEMPERATURE_TYPE_CPU), mName=CPU0, ...}" -- field order and exact
    wording vary across Android versions/OEMs, so this scans each
    `Temperature{...}` block for `mValue=` plus either a `TEMPERATURE_TYPE_*`
    marker or `mName=`, independent of their order within the block.
    """
    result: dict[str, float] = {}
    if not text:
        return result
    for block_match in re.finditer(r"Temperature\{([^}]*)\}", text):
        block = block_match.group(1)
        value_match = re.search(r"mValue=(-?[\d.]+)", block)
        if not value_match:
            continue
        type_match = re.search(r"TEMPERATURE_TYPE_(\w+)", block)
        name_match = re.search(r"mName=([^,}]+)", block)
        key = type_match.group(1) if type_match else (name_match.group(1) if name_match else None)
        if key is None:
            continue
        try:
            result[key.strip().lower()] = float(value_match.group(1))
        except ValueError:
            continue
    return result


def pick_sensor_temp(
    thermal_sensors: dict[str, float], hw_temps: dict[str, float], keywords: list[str]
) -> Optional[float]:
    """Best-effort lookup of a named temperature sensor by keyword.

    Checks the thermalservice sensor map first (actual sensor names,
    matched case-insensitively by substring), then the hardware_properties
    TEMPERATURE_TYPE_* map (matched by exact/substring on the type name).
    """
    for name, value in thermal_sensors.items():
        lname = name.lower()
        if any(keyword in lname for keyword in keywords):
            return value
    for name, value in hw_temps.items():
        if any(keyword in name for keyword in keywords):
            return value
    return None


def parse_foreground_activity(text: str) -> dict[str, Any]:
    """Parse `adb shell dumpsys activity activities` for the foreground
    activity component and a best-effort PiP-mode guess.

    PiP detection is heuristic (Android doesn't expose one canonical,
    version-stable field): looks for "windowingMode=2" (WINDOWING_MODE_
    PINNED) or the literal string "PinnedStack" near the topmost
    resumed-activity record.
    """
    result: dict[str, Any] = {"foreground_activity": UNAVAILABLE, "in_pip": "unknown"}
    if not text:
        return result

    # The label is followed by an "ActivityRecord{<hash> <user> <pkg>/<cls>
    # <task>}" blob on the same line; pull out the "<pkg>/<cls>" component
    # token rather than the first whitespace-delimited word (which would
    # just match "ActivityRecord{...").
    match = re.search(
        r"(?:topResumedActivity|mResumedActivity):.*?([\w.]+/[\w.$]+)", text
    )
    if match:
        result["foreground_activity"] = match.group(1)

    if re.search(r"windowingMode=2\b", text) or "PinnedStack" in text or "isInPip=true" in text:
        result["in_pip"] = "true"
    elif result["foreground_activity"] != UNAVAILABLE:
        result["in_pip"] = "false"

    return result


CODEC_HINT_PATTERNS = (
    re.compile(r"codec[_ ]?name[=:]\s*([\w.\-]+)", re.IGNORECASE),
    re.compile(r"\b(c2\.\w+\.(?:avc|hevc|vp9|av1|vp8|mpeg4)\.decoder)\b", re.IGNORECASE),
    re.compile(r"\b(OMX\.\S*\.(?:avc|hevc|vp9|av1|vp8)\.decoder)\b", re.IGNORECASE),
)


def parse_codec_hint(media_metrics_text: str, package: str) -> str:
    """Best-effort decoder identification from `dumpsys media.metrics`.

    Returns the first plausible decoder/codec component name found near a
    mention of the target package, or UNAVAILABLE if nothing matched. This
    is intentionally a hint, not an authoritative "the app is using codec
    X right now" -- media.metrics output layout is not a stable API.
    """
    if not media_metrics_text:
        return UNAVAILABLE
    # Narrow to blocks mentioning our package where possible, else scan
    # the whole text as a fallback (still safe, worst case over-reports).
    haystack = media_metrics_text
    pkg_index = haystack.find(package)
    if pkg_index != -1:
        haystack = haystack[max(0, pkg_index - 200) : pkg_index + 4000]
    for pattern in CODEC_HINT_PATTERNS:
        match = pattern.search(haystack)
        if match:
            return match.group(1)
    return UNAVAILABLE


ERROR_KEYWORD_PATTERNS = {
    "mediacodec_error_count": re.compile(r"MediaCodec.*error", re.IGNORECASE),
    "egl_error_count": re.compile(r"\bEGL\w*\b.*(error|fail)", re.IGNORECASE),
    "surface_error_count": re.compile(
        r"(Surface|SurfaceTexture).*(error|abandon|invalid)", re.IGNORECASE
    ),
    "pip_error_count": re.compile(
        r"(PipShellNative|PipShellDart|PictureInPicture).*(error|fail|exception)",
        re.IGNORECASE,
    ),
}


def count_logcat_errors(logcat_text: str) -> dict[str, int]:
    """Cumulative keyword-based error counts from the logcat capture so far.

    This is a coarse heuristic (substring/regex match on the whole log),
    not a structured logcat parser -- good enough to notice "things got a
    lot worse in this run" without pretending to be exhaustive.
    """
    counts = {key: 0 for key in ERROR_KEYWORD_PATTERNS}
    if not logcat_text:
        return counts
    for line in logcat_text.splitlines():
        for key, pattern in ERROR_KEYWORD_PATTERNS.items():
            if pattern.search(line):
                counts[key] += 1
    return counts


LOGCAT_KEEP_PATTERN = re.compile(
    r"MediaCodec|Surface|EGL|PipShell|PictureInPicture|ExoPlayer|mpv|"
    r"FATAL EXCEPTION|AndroidRuntime|thermal",
    re.IGNORECASE,
)


def filter_logcat_line(line: str, package: Optional[str] = None) -> bool:
    """Whether a raw logcat line is worth keeping in logcat.txt.

    Keeps player/surface/codec/PiP/crash/thermal related lines plus any
    line mentioning the target package, to keep the saved file readable
    instead of a full-firehose capture.
    """
    if LOGCAT_KEEP_PATTERN.search(line):
        return True
    if package and package in line:
        return True
    return False


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------


def build_sample(
    adb: AdbClient,
    package: str,
    start_time: float,
    logcat_text_so_far: str = "",
) -> dict[str, Any]:
    """Take one snapshot of all metrics. Never raises -- every field that
    can't be read is recorded as UNAVAILABLE.
    """
    now = time.time()
    row: dict[str, Any] = {field: UNAVAILABLE for field in CSV_FIELDS}
    row["timestamp_iso"] = datetime.now(timezone.utc).isoformat()
    row["elapsed_s"] = round(now - start_time, 1)

    battery_text = adb.shell_or_none("dumpsys battery")
    battery = parse_dumpsys_battery(battery_text or "")
    row["battery_level_pct"] = battery["level"] if battery["level"] is not None else UNAVAILABLE
    row["battery_temp_c"] = (
        battery["temperature_c"] if battery["temperature_c"] is not None else UNAVAILABLE
    )
    # `battery_text is None` means adb itself failed to answer (true
    # "unavailable"); don't conflate that with a genuinely-parsed but
    # unrecognized status code, which parse_dumpsys_battery already reports
    # as the string "unknown".
    row["battery_status"] = battery["status"] if battery_text is not None else UNAVAILABLE

    power_supply_dir = "/sys/class/power_supply/battery"
    current_now = adb.shell_or_none(f"cat {power_supply_dir}/current_now")
    voltage_now = adb.shell_or_none(f"cat {power_supply_dir}/voltage_now")
    charge_counter = adb.shell_or_none(f"cat {power_supply_dir}/charge_counter")
    energy_counter = adb.shell_or_none(f"cat {power_supply_dir}/energy_counter")
    supply = parse_power_supply_sysfs(current_now, voltage_now, charge_counter, energy_counter)
    for key in (
        "current_now_raw_ua",
        "current_now_sign",
        "current_now_abs_ma",
        "voltage_now_v",
        "charge_counter_uah",
        "energy_counter_nwh",
    ):
        value = supply[key]
        row[key] = value if value is not None else UNAVAILABLE

    power = estimate_power_w(supply["current_now_abs_ma"], supply["voltage_now_v"])
    row["estimated_power_w"] = round(power, 3) if power is not None else UNAVAILABLE

    cpuinfo_text = adb.shell_or_none("dumpsys cpuinfo")
    cpuinfo = parse_cpuinfo(cpuinfo_text or "", package)
    row["app_pid"] = cpuinfo["pid"] if cpuinfo["pid"] is not None else UNAVAILABLE
    row["app_cpu_pct"] = cpuinfo["app_cpu_pct"] if cpuinfo["app_cpu_pct"] is not None else UNAVAILABLE
    row["total_cpu_pct"] = (
        cpuinfo["total_cpu_pct"] if cpuinfo["total_cpu_pct"] is not None else UNAVAILABLE
    )

    meminfo_text = adb.shell_or_none(f"dumpsys meminfo {package}")
    rss = parse_meminfo_rss(meminfo_text or "")
    row["app_rss_kb"] = rss if rss is not None else UNAVAILABLE

    power_text = adb.shell_or_none("dumpsys power")
    # Same "unavailable" vs. genuinely-parsed-but-unknown distinction as
    # battery_status above: no adb response at all should not read the
    # same as "we asked the device and it didn't tell us".
    row["screen_state"] = parse_screen_state(power_text) if power_text is not None else UNAVAILABLE

    display_text = adb.shell_or_none("dumpsys display")
    refresh_rate = parse_display_refresh_rate(display_text or "")
    row["refresh_rate_hz"] = refresh_rate if refresh_rate is not None else UNAVAILABLE

    activity_text = adb.shell_or_none("dumpsys activity activities")
    activity = parse_foreground_activity(activity_text or "")
    row["foreground_activity"] = activity["foreground_activity"]
    # Same "no adb response" vs. "parsed but couldn't determine" distinction
    # as battery_status/screen_state above.
    row["in_pip"] = activity["in_pip"] if activity_text is not None else UNAVAILABLE

    thermal_text = adb.shell_or_none("dumpsys thermalservice")
    thermal = parse_thermal_status(thermal_text or "")
    row["thermal_status"] = thermal["status"]

    hw_text = adb.shell_or_none("dumpsys hardware_properties")
    hw_temps = parse_hardware_properties_temps(hw_text or "")

    row["temp_battery_c"] = _fmt_temp(
        pick_sensor_temp(thermal["sensors"], hw_temps, ["battery"])
    )
    row["temp_skin_c"] = _fmt_temp(
        pick_sensor_temp(thermal["sensors"], hw_temps, ["skin"])
    )
    row["temp_cpu_c"] = _fmt_temp(
        pick_sensor_temp(thermal["sensors"], hw_temps, ["cpu"])
    )
    row["temp_gpu_c"] = _fmt_temp(
        pick_sensor_temp(thermal["sensors"], hw_temps, ["gpu"])
    )
    row["temp_modem_c"] = _fmt_temp(
        pick_sensor_temp(thermal["sensors"], hw_temps, ["modem"])
    )

    media_metrics_text = adb.shell_or_none("dumpsys media.metrics")
    row["codec_hint"] = parse_codec_hint(media_metrics_text or "", package)

    error_counts = count_logcat_errors(logcat_text_so_far)
    for key, value in error_counts.items():
        row[key] = value

    return row


def _fmt_temp(value: Optional[float]) -> Any:
    return round(value, 1) if value is not None else UNAVAILABLE


# ---------------------------------------------------------------------------
# Snapshots (start/end raw dumps)
# ---------------------------------------------------------------------------


SNAPSHOT_COMMANDS = {
    "battery.txt": "dumpsys battery",
    "thermalservice.txt": "dumpsys thermalservice",
    "hardware_properties.txt": "dumpsys hardware_properties",
    "display.txt": "dumpsys display",
    "activity_activities.txt": "dumpsys activity activities",
    "media_metrics.txt": "dumpsys media.metrics",
    "media_codec.txt": "dumpsys media.codec",
}


def take_snapshot(adb: AdbClient, package: str, out_dir: Path) -> dict[str, bool]:
    """Write the raw dumpsys snapshots requested by the task into out_dir.

    Returns a dict of filename -> whether it was captured successfully,
    so callers can report capture failures in SUMMARY.md instead of
    silently producing an empty/missing file.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    ok: dict[str, bool] = {}

    for filename, command in SNAPSHOT_COMMANDS.items():
        text = adb.shell_or_none(command, timeout=30)
        ok[filename] = text is not None
        (out_dir / filename).write_text(text or "(unavailable)\n", encoding="utf-8")

    gfxinfo = adb.shell_or_none(f"dumpsys gfxinfo {package}", timeout=30)
    ok["gfxinfo.txt"] = gfxinfo is not None
    (out_dir / "gfxinfo.txt").write_text(gfxinfo or "(unavailable)\n", encoding="utf-8")

    meminfo = adb.shell_or_none(f"dumpsys meminfo {package}", timeout=30)
    ok["meminfo.txt"] = meminfo is not None
    (out_dir / "meminfo.txt").write_text(meminfo or "(unavailable)\n", encoding="utf-8")

    batterystats = adb.shell_or_none(f"dumpsys batterystats {package}", timeout=30)
    ok["batterystats.txt"] = batterystats is not None
    (out_dir / "batterystats.txt").write_text(
        batterystats or "(unavailable)\n", encoding="utf-8"
    )

    return ok


# ---------------------------------------------------------------------------
# record subcommand
# ---------------------------------------------------------------------------


def cmd_record(args: argparse.Namespace) -> int:
    adb = AdbClient(adb_path=args.adb, serial=args.serial)
    try:
        adb.ensure_ready()
    except AdbError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.reset_batterystats_before:
        print(
            "WARNING: --reset-batterystats-before will reset the device's "
            "global battery usage history (affects Settings > Battery for "
            "ALL apps, not just PiliPlus). Proceeding because it was "
            "explicitly requested.",
            file=sys.stderr,
        )
        adb.shell_or_none("dumpsys batterystats --reset", timeout=30)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    safe_label = re.sub(r"[^A-Za-z0-9._-]+", "-", args.label).strip("-") or "run"
    out_dir = Path(args.output) / f"{timestamp}-{safe_label}"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "start").mkdir(exist_ok=True)
    (out_dir / "end").mkdir(exist_ok=True)

    print(f"[monitor] writing to {out_dir}")
    print("[monitor] taking start snapshot...")
    start_ok = take_snapshot(adb, args.package, out_dir / "start")

    device_model = (adb.shell_or_none("getprop ro.product.model") or UNAVAILABLE).strip()
    android_release = (adb.shell_or_none("getprop ro.build.version.release") or UNAVAILABLE).strip()
    android_sdk = (adb.shell_or_none("getprop ro.build.version.sdk") or UNAVAILABLE).strip()
    version_name_text = adb.shell_or_none(f"dumpsys package {args.package}") or ""
    version_match = re.search(r"versionName=(\S+)", version_name_text)
    app_version = version_match.group(1) if version_match else UNAVAILABLE

    logcat_path = out_dir / "logcat.txt"
    logcat_proc: Optional[subprocess.Popen] = None
    logcat_lines: list[str] = []
    try:
        adb.shell_or_none("logcat -c", timeout=10)  # clear buffer; safe, not a stats reset
        logcat_proc = adb.popen_logcat()
    except Exception as exc:  # pragma: no cover - best effort, never fatal
        print(f"[monitor] warning: could not start logcat capture: {exc}", file=sys.stderr)

    samples: list[dict[str, Any]] = []
    csv_path = out_dir / "samples.csv"
    interrupted = False
    start_time = time.time()

    with open(csv_path, "w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
        writer.writeheader()

        def handle_sigint(signum, frame):  # noqa: ANN001 - signal handler signature
            nonlocal interrupted
            interrupted = True

        previous_handler = signal.signal(signal.SIGINT, handle_sigint)
        try:
            next_tick = start_time
            while not interrupted and (time.time() - start_time) < args.duration:
                if logcat_proc is not None and logcat_proc.stdout is not None:
                    _drain_nonblocking(logcat_proc, logcat_lines)
                logcat_text = "".join(logcat_lines)

                row = build_sample(adb, args.package, start_time, logcat_text)
                writer.writerow(row)
                csv_file.flush()
                samples.append(row)
                print(
                    f"[monitor] t={row['elapsed_s']:>6}s "
                    f"battery={row['battery_level_pct']}% "
                    f"temp={row['battery_temp_c']}C "
                    f"power~={row['estimated_power_w']}W "
                    f"cpu(app)={row['app_cpu_pct']}%"
                )

                next_tick += args.interval
                sleep_for = next_tick - time.time()
                elapsed_total = time.time() - start_time
                while sleep_for > 0 and not interrupted and elapsed_total < args.duration:
                    time.sleep(min(0.5, sleep_for))
                    sleep_for = next_tick - time.time()
                    elapsed_total = time.time() - start_time
        finally:
            signal.signal(signal.SIGINT, previous_handler)

    if interrupted:
        print("\n[monitor] interrupted by user, finishing up (end snapshot + summary)...")

    if logcat_proc is not None:
        if logcat_proc.stdout is not None:
            _drain_nonblocking(logcat_proc, logcat_lines)
        logcat_proc.terminate()
        try:
            logcat_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            logcat_proc.kill()
    logcat_path.write_text("".join(logcat_lines), encoding="utf-8")

    print("[monitor] taking end snapshot...")
    end_ok = take_snapshot(adb, args.package, out_dir / "end")

    actual_duration_s = round(time.time() - start_time, 1)
    metadata = {
        "label": args.label,
        "package": args.package,
        "requested_duration_s": args.duration,
        "actual_duration_s": actual_duration_s,
        "interval_s": args.interval,
        "interrupted": interrupted,
        "sample_count": len(samples),
        "expected_sample_count": max(1, args.duration // max(1, args.interval)),
        "started_at": datetime.fromtimestamp(start_time, tz=timezone.utc).isoformat(),
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "device_model": device_model,
        "android_release": android_release,
        "android_sdk": android_sdk,
        "app_version_name": app_version,
        "adb_serial": adb.serial,
        "snapshot_start_ok": start_ok,
        "snapshot_end_ok": end_ok,
        "reset_batterystats_before": args.reset_batterystats_before,
        "note": (
            "Short single-shot samples are NOT a substitute for real battery "
            "life measurement. See docs/POWER_TEST_GUIDE.md."
        ),
    }
    (out_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    summary = build_summary_markdown(metadata, samples)
    (out_dir / "SUMMARY.md").write_text(summary, encoding="utf-8")

    print(f"\n[monitor] done. Report: {out_dir}")
    print(f"[monitor] samples: {len(samples)}, interrupted: {interrupted}")
    return 0


def _drain_nonblocking(proc: subprocess.Popen, sink: list[str]) -> None:
    """Best-effort, non-blocking drain of a Popen's stdout into `sink`.

    Uses a short-timeout readline loop rather than a raw non-blocking fd
    read so it behaves the same on Windows and POSIX (Windows doesn't
    support fcntl-based non-blocking pipe reads).
    """
    import selectors

    if proc.stdout is None:
        return
    if sys.platform == "win32":
        # No selectors support for pipes on Windows; logcat draining there
        # is handled by the final drain after terminate() instead of live
        # streaming mid-loop, to avoid blocking the sampling cadence.
        return
    sel = selectors.DefaultSelector()
    try:
        sel.register(proc.stdout, selectors.EVENT_READ)
        while sel.select(timeout=0):
            line = proc.stdout.readline()
            if not line:
                break
            sink.append(line)
    finally:
        sel.close()


# ---------------------------------------------------------------------------
# Summary / compare
# ---------------------------------------------------------------------------


def _numeric_values(samples: list[dict[str, Any]], field: str) -> list[float]:
    values = []
    for row in samples:
        value = row.get(field)
        if value in (None, UNAVAILABLE, ""):
            continue
        try:
            values.append(float(value))
        except (TypeError, ValueError):
            continue
    return values


def _missing_rate(samples: list[dict[str, Any]], field: str) -> float:
    if not samples:
        return 1.0
    missing = sum(1 for row in samples if row.get(field) in (None, UNAVAILABLE, ""))
    return missing / len(samples)


def build_summary_markdown(metadata: dict[str, Any], samples: list[dict[str, Any]]) -> str:
    lines: list[str] = []
    label = metadata.get("label", "run")
    lines.append(f"# Power/thermal summary: {label}")
    lines.append("")
    lines.append(
        "**Short single-shot samples are NOT equivalent to full battery-life "
        "testing.** Treat this as a rough, single-run signal -- repeat several "
        "times and compare with `compare` before drawing conclusions. See "
        "docs/POWER_TEST_GUIDE.md."
    )
    lines.append("")

    lines.append("## Run info")
    lines.append("")
    lines.append(f"- Package: `{metadata.get('package')}`")
    lines.append(f"- Device: {metadata.get('device_model')} / Android {metadata.get('android_release')} (SDK {metadata.get('android_sdk')})")
    lines.append(f"- App version: {metadata.get('app_version_name')}")
    lines.append(
        f"- Requested duration: {metadata.get('requested_duration_s')}s, "
        f"actual: {metadata.get('actual_duration_s')}s "
        f"({'interrupted' if metadata.get('interrupted') else 'completed'})"
    )
    lines.append(
        f"- Samples collected: {metadata.get('sample_count')} "
        f"(expected ~{metadata.get('expected_sample_count')})"
    )
    lines.append("")

    if not samples:
        lines.append("No samples were collected (run interrupted immediately or adb failed).")
        return "\n".join(lines) + "\n"

    level_values = _numeric_values(samples, "battery_level_pct")
    temp_values = _numeric_values(samples, "battery_temp_c")
    current_values = _numeric_values(samples, "current_now_abs_ma")
    power_values = _numeric_values(samples, "estimated_power_w")
    app_cpu_values = _numeric_values(samples, "app_cpu_pct")
    rss_values = _numeric_values(samples, "app_rss_kb")

    lines.append("## Battery")
    lines.append("")
    if level_values:
        lines.append(f"- Level: {level_values[0]:.0f}% -> {level_values[-1]:.0f}% (delta {level_values[-1] - level_values[0]:+.0f}%)")
    else:
        lines.append("- Level: unavailable")
    if current_values:
        lines.append(
            f"- Absolute current (mA): mean={statistics.mean(current_values):.1f}, "
            f"median={statistics.median(current_values):.1f}, "
            f"max={max(current_values):.1f}"
        )
    else:
        lines.append("- Absolute current: unavailable")
    if power_values:
        lines.append(
            f"- Estimated power (W, |I|*V): mean={statistics.mean(power_values):.2f}, "
            f"median={statistics.median(power_values):.2f} "
            "(estimate only, not a calibrated power-rail measurement)"
        )
    else:
        lines.append("- Estimated power: unavailable")
    lines.append("")

    lines.append("## Thermal")
    lines.append("")
    if temp_values:
        rise = temp_values[-1] - temp_values[0]
        duration_min = max(metadata.get("actual_duration_s", 1), 1) / 60.0
        lines.append(
            f"- Battery temperature: start={temp_values[0]:.1f}C, "
            f"max={max(temp_values):.1f}C, end={temp_values[-1]:.1f}C"
        )
        lines.append(
            f"- Temperature rise: {rise:+.1f}C over {duration_min:.1f} min "
            f"({rise / duration_min:+.2f} C/min)"
        )
    else:
        lines.append("- Battery temperature: unavailable")
    thermal_statuses = sorted(
        {row.get("thermal_status") for row in samples if row.get("thermal_status") not in (None, UNAVAILABLE)}
    )
    lines.append(f"- ThermalStatus values observed: {thermal_statuses or 'unavailable'}")
    lines.append("")

    lines.append("## App load")
    lines.append("")
    if app_cpu_values:
        lines.append(
            f"- App CPU%: mean={statistics.mean(app_cpu_values):.1f}, "
            f"peak={max(app_cpu_values):.1f}"
        )
    else:
        lines.append("- App CPU%: unavailable")
    if rss_values:
        lines.append(
            f"- App RSS (kB): mean={statistics.mean(rss_values):.0f}, "
            f"peak={max(rss_values):.0f}"
        )
    else:
        lines.append("- App RSS: unavailable")
    codec_hints = sorted(
        {row.get("codec_hint") for row in samples if row.get("codec_hint") not in (None, UNAVAILABLE)}
    )
    lines.append(f"- Decoder hints observed: {codec_hints or 'unavailable'}")
    lines.append("")

    pip_true = sum(1 for row in samples if row.get("in_pip") == "true")
    pip_known = sum(1 for row in samples if row.get("in_pip") in ("true", "false"))
    lines.append("## PiP coverage")
    lines.append("")
    if pip_known:
        lines.append(f"- Samples in PiP: {pip_true}/{pip_known} ({100 * pip_true / pip_known:.0f}%)")
    else:
        lines.append("- PiP state: unavailable")
    lines.append("")

    error_fields = ["mediacodec_error_count", "egl_error_count", "surface_error_count", "pip_error_count"]
    lines.append("## Error counters (cumulative, keyword-matched logcat)")
    lines.append("")
    for field in error_fields:
        values = _numeric_values(samples, field)
        final = int(values[-1]) if values else "unavailable"
        lines.append(f"- {field}: {final}")
    lines.append("")

    lines.append("## Field capture failures")
    lines.append("")
    failure_lines = []
    for field in CSV_FIELDS:
        if field in ("timestamp_iso", "elapsed_s"):
            continue
        rate = _missing_rate(samples, field)
        if rate > 0:
            failure_lines.append(f"- `{field}`: unavailable in {rate * 100:.0f}% of samples")
    if failure_lines:
        lines.extend(failure_lines)
    else:
        lines.append("- None -- every field was captured in every sample.")
    lines.append("")

    return "\n".join(lines) + "\n"


def load_run(run_dir: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    metadata_path = run_dir / "metadata.json"
    samples_path = run_dir / "samples.csv"
    metadata: dict[str, Any] = {}
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    samples: list[dict[str, Any]] = []
    if samples_path.exists():
        with open(samples_path, newline="", encoding="utf-8") as fh:
            samples = list(csv.DictReader(fh))
    return metadata, samples


def resolve_run_dirs(patterns: list[str]) -> list[Path]:
    resolved: list[Path] = []
    for pattern in patterns:
        path = Path(pattern)
        if path.is_dir():
            resolved.append(path)
            continue
        matches = sorted(glob.glob(pattern))
        resolved.extend(Path(m) for m in matches if Path(m).is_dir())
    # De-duplicate while preserving order.
    seen: set[Path] = set()
    unique: list[Path] = []
    for path in resolved:
        resolved_path = path.resolve()
        if resolved_path not in seen:
            seen.add(resolved_path)
            unique.append(path)
    return unique


def cmd_compare(args: argparse.Namespace) -> int:
    run_dirs = resolve_run_dirs(args.runs)
    if len(run_dirs) < 2:
        print(
            f"error: need at least 2 run directories to compare, resolved {len(run_dirs)} "
            f"from patterns {args.runs}",
            file=sys.stderr,
        )
        return 1

    runs = []
    for run_dir in run_dirs:
        metadata, samples = load_run(run_dir)
        if not samples:
            print(f"warning: {run_dir} has no samples.csv rows, skipping", file=sys.stderr)
            continue
        runs.append((run_dir, metadata, samples))

    if len(runs) < 2:
        print("error: fewer than 2 runs had usable samples", file=sys.stderr)
        return 1

    markdown = build_compare_markdown(runs)
    print(markdown)
    if args.output:
        Path(args.output).write_text(markdown, encoding="utf-8")
        print(f"\n[monitor] comparison written to {args.output}", file=sys.stderr)
    return 0


def build_compare_markdown(
    runs: list[tuple[Path, dict[str, Any], list[dict[str, Any]]]],
) -> str:
    lines: list[str] = []
    lines.append("# Power comparison")
    lines.append("")
    lines.append(
        "| Run | Duration(s) | Mean I (mA) | Median I (mA) | Est. power (W) | "
        "Temp rise (C) | Rise (C/min) | App CPU% mean | App RSS mean (kB) | "
        "Max ThermalStatus | Battery drop (%) | Missing-sample rate |"
    )
    lines.append(
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|"
    )

    thermal_order = list(THERMAL_STATUS_NAMES.values())

    rows_info = []
    for run_dir, metadata, samples in runs:
        label = metadata.get("label") or run_dir.name
        duration = metadata.get("actual_duration_s", "?")
        current_values = _numeric_values(samples, "current_now_abs_ma")
        power_values = _numeric_values(samples, "estimated_power_w")
        temp_values = _numeric_values(samples, "battery_temp_c")
        cpu_values = _numeric_values(samples, "app_cpu_pct")
        rss_values = _numeric_values(samples, "app_rss_kb")
        level_values = _numeric_values(samples, "battery_level_pct")

        mean_i = statistics.mean(current_values) if current_values else None
        median_i = statistics.median(current_values) if current_values else None
        mean_power = statistics.mean(power_values) if power_values else None
        rise = (temp_values[-1] - temp_values[0]) if len(temp_values) >= 2 else None
        rise_per_min = (
            rise / (float(duration) / 60.0) if rise is not None and isinstance(duration, (int, float)) and duration else None
        )
        mean_cpu = statistics.mean(cpu_values) if cpu_values else None
        mean_rss = statistics.mean(rss_values) if rss_values else None
        battery_drop = (level_values[0] - level_values[-1]) if len(level_values) >= 2 else None

        thermal_statuses = [
            row.get("thermal_status") for row in samples if row.get("thermal_status") in thermal_order
        ]
        max_thermal = (
            max(thermal_statuses, key=lambda s: thermal_order.index(s)) if thermal_statuses else "unavailable"
        )

        missing_rate = statistics.mean(
            [_missing_rate(samples, field) for field in CSV_FIELDS if field not in ("timestamp_iso", "elapsed_s")]
        )

        def fmt(value: Optional[float], digits: int = 1) -> str:
            return f"{value:.{digits}f}" if value is not None else "n/a"

        lines.append(
            f"| {label} | {duration} | {fmt(mean_i)} | {fmt(median_i)} | {fmt(mean_power, 2)} | "
            f"{fmt(rise)} | {fmt(rise_per_min, 2)} | {fmt(mean_cpu)} | {fmt(mean_rss, 0)} | "
            f"{max_thermal} | {fmt(battery_drop)} | {missing_rate * 100:.0f}% |"
        )
        rows_info.append(
            {
                "label": label,
                "duration": duration,
                "initial_temp": temp_values[0] if temp_values else None,
                "charging": metadata.get("battery_status_start"),
                "missing_rate": missing_rate,
            }
        )

    lines.append("")
    lines.append("## Comparability caveats")
    lines.append("")

    durations = {info["duration"] for info in rows_info}
    if len(durations) > 1:
        lines.append(f"- **Different test durations**: {sorted(durations, key=str)} -- normalize by rate (C/min, mean current) rather than comparing totals directly.")

    initial_temps = [info["initial_temp"] for info in rows_info if info["initial_temp"] is not None]
    if len(initial_temps) >= 2 and (max(initial_temps) - min(initial_temps)) > 1.0:
        lines.append(
            f"- **Different starting battery temperature** across runs (range "
            f"{min(initial_temps):.1f}C - {max(initial_temps):.1f}C): let the device "
            "cool to a similar baseline between runs before comparing temperature rise."
        )

    high_missing = [info["label"] for info in rows_info if info["missing_rate"] > 0.2]
    if high_missing:
        lines.append(
            f"- **High missing-sample rate (>20%)** in: {high_missing} -- treat those "
            "runs' numbers as low-confidence."
        )

    lines.append(
        "- This tool cannot detect charging state reliably across OEM sign "
        "conventions on `current_now`; cross-check `battery_status` in each "
        "run's SUMMARY.md and exclude runs that were charging."
    )
    lines.append(
        "- All of the above are single-run snapshots. Repeat each scenario "
        "multiple times (see docs/POWER_TEST_GUIDE.md) before concluding "
        "one configuration is meaningfully better than another."
    )
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="monitor_piliplus_power.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    record_parser = subparsers.add_parser("record", help="Record one power/thermal sampling run.")
    record_parser.add_argument("--adb", default="adb", help="Path to the adb executable (default: adb on PATH).")
    record_parser.add_argument("--serial", default=None, help="Target device serial (required if multiple devices are connected).")
    record_parser.add_argument("--package", default=DEFAULT_PACKAGE, help=f"App package name (default: {DEFAULT_PACKAGE}).")
    record_parser.add_argument("--label", required=True, help="Short label for this run, used in the output directory name.")
    record_parser.add_argument("--duration", type=int, default=DEFAULT_DURATION_S, help=f"Total recording duration in seconds (default: {DEFAULT_DURATION_S}).")
    record_parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL_S, help=f"Sampling interval in seconds (default: {DEFAULT_INTERVAL_S}).")
    record_parser.add_argument("--output", default=str(DEFAULT_OUTPUT_ROOT), help=f"Base output directory (default: {DEFAULT_OUTPUT_ROOT}).")
    record_parser.add_argument(
        "--reset-batterystats-before",
        action="store_true",
        help=(
            "DESTRUCTIVE, opt-in only: run `dumpsys batterystats --reset` before "
            "recording. This clears the device's global battery usage history "
            "for ALL apps, not just PiliPlus. Off by default."
        ),
    )
    record_parser.set_defaults(func=cmd_record)

    compare_parser = subparsers.add_parser("compare", help="Compare two or more recorded runs.")
    compare_parser.add_argument("runs", nargs="+", help="Run directories or glob patterns (e.g. .review/power/*-pip-subtitle-on-*).")
    compare_parser.add_argument("--output", default=None, help="Optional path to also write the comparison Markdown to.")
    compare_parser.set_defaults(func=cmd_compare)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
