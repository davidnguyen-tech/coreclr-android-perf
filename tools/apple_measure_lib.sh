#!/bin/bash
# =============================================================================
# tools/apple_measure_lib.sh — Shared helper functions for Apple startup
# measurement scripts.
#
# This library is sourced by the platform-specific measurement scripts:
#   - osx/measure_osx_startup.sh
#   - maccatalyst/measure_maccatalyst_startup.sh
#   - ios/measure_simulator_startup.sh
#   - ios/measure_device_startup.sh
#
# It provides:
#   - High-resolution timing helpers (nanosecond timestamps, elapsed ms)
#   - Window-appearance detection for macOS / Mac Catalyst (via AppleScript)
#   - Log stream event detection for iOS Simulator
#   - Post-hoc device log collection + SpringBoard Watchdog timing for iOS devices
#   - Device management helpers (install, launch, terminate, uninstall)
#   - Process detection (wait for process by name)
#   - Statistics computation (avg, median, min, max, stdev)
#   - Build time measurement (binlog parsing via dotnet/performance)
#   - Output formatting (parseable summary lines for measure_all.sh)
#   - CSV result saving
#
# Usage:
#   source "$(dirname "$0")/../tools/apple_measure_lib.sh"
#
# NOTE: This file is a pure function library. No code executes at source time.
# =============================================================================

# Double-source guard
[ -n "${_APPLE_MEASURE_LIB_LOADED:-}" ] && return 0
_APPLE_MEASURE_LIB_LOADED=1

# Source the shared nettrace validation library.
# Uses BASH_SOURCE to resolve the path relative to this script (both files live in tools/).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate-nettrace.sh"

# =============================================================================
# Prerequisite validation
# =============================================================================

# Check that python3 is available. Call this during script prerequisite checks.
# Usage: requires_python3
requires_python3() {
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required but not found."
        return 1
    fi
    return 0
}

# =============================================================================
# Timing helpers
# =============================================================================

# Capture a high-resolution timestamp in nanoseconds.
# Uses python3 because macOS `date` does not support %N.
# Usage: ts=$(get_timestamp_ns)
get_timestamp_ns() {
    python3 -c "import time; print(time.time_ns())"
}

# Compute elapsed milliseconds between two nanosecond timestamps.
# Output is formatted to 2 decimal places.
# Usage: ms=$(elapsed_ms "$start_ns" "$end_ns")
elapsed_ms() {
    local start_ns="$1"
    local end_ns="$2"
    python3 -c "print(f'{($end_ns - $start_ns) / 1_000_000:.2f}')"
}

# =============================================================================
# macOS / Mac Catalyst: window-appearance detection
# =============================================================================

# Poll for the app's first on-screen window using System Events AppleScript.
# This is the primary timing mechanism for macOS and Mac Catalyst apps: after
# the `open` command launches the app asynchronously, this function polls
# until the app has at least one visible window, indicating it has finished
# rendering its initial UI.
#
# IMPORTANT: This requires Accessibility permissions for the terminal/shell.
# On first use, macOS will prompt to grant "System Events" access to your
# terminal application (Terminal.app, iTerm2, etc.). This is a one-time grant.
#
# Arguments:
#   $1 - executable_name  The process name as shown in System Events
#                         (typically the CFBundleExecutable value)
#   $2 - timeout          Maximum seconds to wait (default: 30)
#   $3 - poll_interval    Seconds between polls (default: 0.05 = 50ms)
#
# Returns:
#   0 - Window detected
#   1 - Timeout (no window appeared within the timeout period)
#
# Usage: wait_for_window "$EXECUTABLE_NAME" 30 0.05
wait_for_window() {
    local executable_name="$1"
    local timeout="${2:-30}"
    local poll_interval="${3:-0.05}"
    local deadline=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$deadline" ]; do
        local has_window
        has_window=$(osascript -e "
            tell application \"System Events\"
                set appProcs to every process whose name is \"$executable_name\"
                if (count of appProcs) > 0 then
                    set appProc to item 1 of appProcs
                    if (count of windows of appProc) > 0 then
                        return \"yes\"
                    end if
                end if
            end tell
            return \"no\"
        " 2>/dev/null)

        if [ "$has_window" = "yes" ]; then
            return 0
        fi
        sleep "$poll_interval"
    done

    return 1  # timeout
}

# =============================================================================
# iOS Simulator: log stream event detection
# =============================================================================

# Variables set by start_log_stream / cleaned up by stop_log_stream.
# These are intentionally global so the caller can reference them.
_AML_LOG_STREAM_PID=""
_AML_LOG_STREAM_FILE=""

# Start a background `log stream` filtered for a specific process name.
# This should be called BEFORE launching the app so that the log stream
# is already connected when the first events arrive.
#
# Sets:
#   _AML_LOG_STREAM_PID  - PID of the background log stream process
#   _AML_LOG_STREAM_FILE - Path to the temp file collecting log output
#
# Arguments:
#   $1 - predicate  A `log stream --predicate` expression
#                   (e.g., "process == \"MyApp\"")
#   $2 - settle     Seconds to wait after starting the stream to ensure
#                   it is connected (default: 0.5)
#
# Usage: start_log_stream "process == \"MyApp\"" 0.5
start_log_stream() {
    stop_log_stream
    local predicate="$1"
    local settle="${2:-0.5}"

    _AML_LOG_STREAM_FILE=$(mktemp /tmp/apple_measure_log.XXXXXX)

    log stream --predicate "$predicate" \
        --style ndjson --level info > "$_AML_LOG_STREAM_FILE" 2>/dev/null &
    _AML_LOG_STREAM_PID=$!

    # Brief pause to ensure the log stream is connected before we launch the app
    sleep "$settle"
}

# Stop the background log stream and clean up the temp file.
# Safe to call even if start_log_stream was never called.
# Usage: stop_log_stream
stop_log_stream() {
    if [ -n "${_AML_LOG_STREAM_PID:-}" ]; then
        kill "$_AML_LOG_STREAM_PID" 2>/dev/null || true
        wait "$_AML_LOG_STREAM_PID" 2>/dev/null || true
        _AML_LOG_STREAM_PID=""
    fi
    if [ -n "${_AML_LOG_STREAM_FILE:-}" ] && [ -f "$_AML_LOG_STREAM_FILE" ]; then
        rm -f "$_AML_LOG_STREAM_FILE"
        _AML_LOG_STREAM_FILE=""
    fi
}

# Wait for a matching log event to appear in the log stream output file.
# Polls the temp file created by start_log_stream for any line containing
# the specified process name.
#
# Arguments:
#   $1 - process_name  The process name to search for in log entries
#   $2 - timeout       Maximum seconds to wait (default: 30)
#   $3 - poll_interval Seconds between polls (default: 0.1)
#
# Returns:
#   0 - Matching event found (timestamp is printed to stdout if available)
#   1 - Timeout (no matching event within the timeout period)
#
# Usage:
#   start_log_stream "process == \"MyApp\""
#   # ... launch the app ...
#   wait_for_log_event "MyApp" 30
wait_for_log_event() {
    local process_name="$1"
    local timeout="${2:-30}"
    local poll_interval="${3:-0.1}"
    local deadline=$((SECONDS + timeout))

    if [ -z "${_AML_LOG_STREAM_FILE:-}" ] || [ ! -f "$_AML_LOG_STREAM_FILE" ]; then
        echo "Error: log stream not started. Call start_log_stream first." >&2
        return 1
    fi

    while [ "$SECONDS" -lt "$deadline" ]; do
        # Check if the log file contains any entry mentioning the process.
        # Use grep for speed — we just need to know if any line matches.
        if grep -q "$process_name" "$_AML_LOG_STREAM_FILE" 2>/dev/null; then
            # Found a match. Try to extract the timestamp from the first
            # matching ndjson line.
            local ts
            ts=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            proc = entry.get('processImagePath', '') or entry.get('process', '')
            if sys.argv[2] in str(proc):
                print(entry.get('timestamp', 'found'))
                sys.exit(0)
        except (json.JSONDecodeError, KeyError):
            continue
sys.exit(1)
" "$_AML_LOG_STREAM_FILE" "$process_name" 2>/dev/null)

            if [ -n "$ts" ]; then
                echo "$ts"
                return 0
            fi
            # grep matched but python3 didn't parse a valid entry yet —
            # could be a partial write. Keep polling.
        fi
        sleep "$poll_interval"
    done

    return 1  # timeout
}

# =============================================================================
# iOS Device: startup timing via sudo log collect --device
# =============================================================================
# Uses post-hoc log collection to extract SpringBoard Watchdog timing events,
# following the same approach as dotnet/performance's runner.py.
#
# Background:
#   `log stream --device` does NOT exist — the --device flag is only valid on
#   `log collect`. Physical device logs are not accessible via the host's
#   `log stream` command (which only reads the local unified log).
#
# Flow (per iteration):
#   1. Launch the app via xcrun devicectl
#   2. Wait for the app to fully start (sleep 5s)
#   3. Collect device logs post-hoc: sudo log collect --device --start <ts>
#   4. Parse the .logarchive for SpringBoard Watchdog events
#   5. Extract time-to-main and time-to-first-draw from event timestamps
#
# Requires: passwordless sudo configured for `log collect --device`.
#
# See: .github/researches/ios-device-log-streaming.md for full analysis.

# Collect device logs for a time window into a .logarchive file.
# Requires: passwordless sudo configured for '/usr/bin/log'.
#
# Arguments:
#   $1 - device_udid      Target device UDID (reserved for future multi-device support)
#   $2 - start_timestamp  Start time in "YYYY-MM-DD HH:MM:SS±ZZZZ" format
#   $3 - output_path      Path for the output .logarchive (directory)
#
# Note: Uses --device (not --device-udid) because log collect expects hardware
# UDIDs (00008020-...) while xcrun devicectl provides CoreDevice UUIDs.
# --device targets the first connected device, matching runner.py's approach.
#
# Returns:
#   0 - Collection succeeded
#   1 - Collection failed
collect_device_logs() {
    local device_udid="$1"
    local start_timestamp="$2"
    local output_path="$3"

    if [ -z "$device_udid" ] || [ -z "$start_timestamp" ] || [ -z "$output_path" ]; then
        echo "Error: collect_device_logs requires device_udid, start_timestamp, and output_path." >&2
        return 1
    fi

    # Remove previous logarchive at this path if it exists
    rm -rf "$output_path"

    local collect_output
    collect_output=$(sudo log collect --device \
        --start "$start_timestamp" \
        --output "$output_path" 2>&1)
    local collect_exit=$?

    if [ $collect_exit -ne 0 ] || [ ! -d "$output_path" ]; then
        echo "Error: 'sudo log collect' failed (exit $collect_exit)." >&2
        echo "  Ensure passwordless sudo is configured for /usr/bin/log." >&2
        echo "  Add to /etc/sudoers: $(whoami) ALL=(ALL) NOPASSWD: /usr/bin/log" >&2
        echo "  Output: $collect_output" >&2
        return 1
    fi
    return 0
}

# Parse SpringBoard Watchdog events from a .logarchive file.
# Extracts time-to-main and time-to-first-draw for a given bundle ID,
# plus the timestamp of the last event (for device-side time reference).
#
# SpringBoard emits 4 Watchdog events during app startup:
#   1. "Now monitoring resource allowance of 20.00s" — OS starts watching main()
#   2. "Stopped monitoring."                         — App reached main()
#   3. "Now monitoring resource allowance of N.NNs"  — OS starts watching first draw
#   4. "Stopped monitoring."                         — App drew first frame
#
# Time-to-main    = Event 2 timestamp - Event 1 timestamp
# Time-to-draw    = Event 4 timestamp - Event 3 timestamp
# Total startup   = time-to-main + time-to-draw
#
# This function also returns the last event's timestamp, eliminating the need
# for a separate get_last_watchdog_timestamp() call (which would re-read the
# same logarchive). The caller uses this timestamp to set the --start window
# for the next iteration's log collection.
#
# Arguments:
#   $1 - logarchive_path  Path to the .logarchive directory
#   $2 - bundle_id        App bundle identifier (e.g., "com.companyname.myapp")
#
# Output (stdout, 4 lines on success):
#   Line 1: total_ms      (time-to-main + time-to-first-draw)
#   Line 2: time_to_main_ms
#   Line 3: time_to_first_draw_ms
#   Line 4: last_event_timestamp (e.g., "2024-01-15 10:30:45.123456+0000")
#
# Returns:
#   0 - Parsing succeeded (4 lines printed)
#   1 - Parsing failed (wrong number of events, parse error, etc.)
parse_watchdog_timing() {
    local logarchive_path="$1"
    local bundle_id="$2"

    if [ -z "$logarchive_path" ] || [ ! -d "$logarchive_path" ]; then
        echo "Error: logarchive path '$logarchive_path' does not exist." >&2
        return 1
    fi
    if [ -z "$bundle_id" ]; then
        echo "Error: bundle_id is required for Watchdog event parsing." >&2
        return 1
    fi

    # Extract Watchdog events as ndjson
    local events_json
    events_json=$(log show \
        --predicate '(process == "SpringBoard") && (category == "Watchdog")' \
        --info --style ndjson \
        "$logarchive_path" 2>/dev/null)

    if [ -z "$events_json" ]; then
        echo "Error: No SpringBoard Watchdog events found in logarchive." >&2
        return 1
    fi

    # Parse with Python, following runner.py logic (lines 825-931)
    python3 -c "
import json, sys
from datetime import datetime

bundle_id = sys.argv[1]
events = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
        msg = entry.get('eventMessage', '')
        if bundle_id in msg and ('Now monitoring resource allowance' in msg or 'Stopped monitoring' in msg):
            events.append(entry)
    except (json.JSONDecodeError, KeyError):
        continue

if len(events) < 4:
    print(f'ERROR: Expected 4 Watchdog events for {bundle_id}, got {len(events)}', file=sys.stderr)
    if events:
        for e in events:
            print(f'  Event: {e.get(\"eventMessage\", \"?\")[:120]}', file=sys.stderr)
    sys.exit(1)

# Use the last 4 events (in case there are extras from previous runs)
events = events[-4:]
e0, e1, e2, e3 = events

# Validate event sequence
if 'Now monitoring resource allowance of 20.00s' not in e0.get('eventMessage', ''):
    print(f'ERROR: Invalid first event (expected 20.00s monitor start): {e0.get(\"eventMessage\", \"\")}', file=sys.stderr)
    sys.exit(1)

if 'Stopped monitoring' not in e1.get('eventMessage', ''):
    print(f'ERROR: Invalid second event (expected Stopped monitoring): {e1.get(\"eventMessage\", \"\")}', file=sys.stderr)
    sys.exit(1)

if 'Now monitoring resource allowance of' not in e2.get('eventMessage', ''):
    print(f'ERROR: Invalid third event (expected monitor start): {e2.get(\"eventMessage\", \"\")}', file=sys.stderr)
    sys.exit(1)

if 'Stopped monitoring' not in e3.get('eventMessage', ''):
    print(f'ERROR: Invalid fourth event (expected Stopped monitoring): {e3.get(\"eventMessage\", \"\")}', file=sys.stderr)
    sys.exit(1)

# Parse timestamps
fmt = '%Y-%m-%d %H:%M:%S.%f%z'
t0 = datetime.strptime(e0['timestamp'], fmt)
t1 = datetime.strptime(e1['timestamp'], fmt)
t2 = datetime.strptime(e2['timestamp'], fmt)
t3 = datetime.strptime(e3['timestamp'], fmt)

time_to_main_ms = (t1 - t0).total_seconds() * 1000
time_to_first_draw_ms = (t3 - t2).total_seconds() * 1000
total_ms = time_to_main_ms + time_to_first_draw_ms

# Line 1: total ms, Line 2: time-to-main ms, Line 3: time-to-draw ms
# Line 4: last event timestamp (for device-side time reference)
print(f'{total_ms:.2f}')
print(f'{time_to_main_ms:.2f}')
print(f'{time_to_first_draw_ms:.2f}')
print(e3['timestamp'])
" "$bundle_id" <<< "$events_json"
}

# Extract the device-side timestamp of the last Watchdog event from a logarchive.
# Used by the warmup iteration to establish a device time reference, avoiding
# host-device clock drift issues (same technique as runner.py lines 859-863).
#
# DEPRECATED for real measurement iterations: parse_watchdog_timing() now
# returns the last event timestamp as its 4th output line, eliminating the
# need for a separate log show call. This function is retained for the warmup
# iteration where we only need the timestamp (not the timing data).
#
# Arguments:
#   $1 - logarchive_path  Path to the .logarchive directory
#   $2 - bundle_id        App bundle identifier
#
# Output (stdout): timestamp string in "YYYY-MM-DD HH:MM:SS.ffffff±ZZZZ" format
#                  (empty if no events found)
#
# Returns:
#   0 - Timestamp found
#   1 - No matching events
get_last_watchdog_timestamp() {
    local logarchive_path="$1"
    local bundle_id="$2"

    if [ -z "$logarchive_path" ] || [ ! -d "$logarchive_path" ]; then
        return 1
    fi

    local events_json
    events_json=$(log show \
        --predicate '(process == "SpringBoard") && (category == "Watchdog")' \
        --info --style ndjson \
        "$logarchive_path" 2>/dev/null)

    if [ -z "$events_json" ]; then
        return 1
    fi

    python3 -c "
import json, sys

bundle_id = sys.argv[1]
last_ts = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
        msg = entry.get('eventMessage', '')
        if bundle_id in msg and ('Now monitoring resource allowance' in msg or 'Stopped monitoring' in msg):
            last_ts = entry.get('timestamp', '')
    except (json.JSONDecodeError, KeyError):
        continue

if last_ts:
    print(last_ts)
else:
    sys.exit(1)
" "$bundle_id" <<< "$events_json"
}

# Advance a device-side Watchdog timestamp by N seconds.
# Used to compute the --start argument for the next iteration's log collect,
# avoiding overlap with events from the current iteration.
#
# Arguments:
#   $1 - timestamp  Device-side timestamp (e.g., "2024-01-15 10:30:45.123456+0000")
#   $2 - seconds    Seconds to add (default: 1)
#
# Output (stdout): adjusted timestamp in "YYYY-MM-DD HH:MM:SS±HHMM" format
#                  (suitable for `sudo log collect --start`)
advance_timestamp() {
    local timestamp="$1"
    local seconds="${2:-1}"

    python3 -c "
from datetime import datetime, timedelta
import sys

ts_str = sys.argv[1]
delta_s = int(sys.argv[2])

# Parse device timestamp (format: 'YYYY-MM-DD HH:MM:SS.ffffff±ZZZZ')
fmt = '%Y-%m-%d %H:%M:%S.%f%z'
dt = datetime.strptime(ts_str, fmt)
dt = dt + timedelta(seconds=delta_s)

# Output in the format expected by 'log collect --start'
print(dt.strftime('%Y-%m-%d %H:%M:%S%z'))
" "$timestamp" "$seconds"
}

# =============================================================================
# iOS Device: device management helpers (xcrun devicectl)
# =============================================================================

# Find the UDID of a connected physical iOS device.
# Uses `xcrun devicectl list devices` (Xcode 15+) with JSON output.
#
# If multiple devices are connected, returns the first one.
# If no device is connected, returns empty string.
#
# Falls back to `xcrun xctrace list devices` if `devicectl` is not available
# (older Xcode versions).
#
# Arguments: none
#
# Output: UDID string on stdout (or empty)
#
# Usage:
#   DEVICE_UDID=$(get_connected_device_udid)
#   if [ -z "$DEVICE_UDID" ]; then echo "No device"; fi
get_connected_device_udid() {
    # Use a temp file for JSON output — piping via /dev/stdout produces mixed
    # text+JSON that python's json.load(sys.stdin) cannot parse.
    # See: .github/researches/ios-device-udid-mismatch.md
    local json_file
    json_file=$(mktemp /tmp/devicectl_devices.XXXXXX.json)
    trap "rm -f '$json_file'" RETURN

    xcrun devicectl list devices --json-output "$json_file" >/dev/null 2>&1

    local udid
    udid=$(python3 -c "
import json, sys
try:
    data = json.load(open('$json_file'))
    devices = data.get('result', {}).get('devices', [])
    for d in devices:
        conn = d.get('connectionProperties', {})
        hw = d.get('hardwareProperties', {})
        # Only consider iOS/iPadOS devices connected via USB (wired).
        # IMPORTANT: 'localNetwork' matches the host Mac itself (which appears as a
        # CoreDevice), and 'wifi' is unreliable for device operations. Always use
        # 'wired' only. See: .github/researches/ios-device-udid-mismatch.md
        if conn.get('transportType', '') == 'wired' and hw.get('platform', '') in ('iOS', 'iPadOS'):
            # Returns the CoreDevice identifier (UUID format), which is what
            # 'xcrun devicectl' commands expect for --device.
            # NOTE: 'sudo log collect --device-udid' may expect the hardware UDID
            # (from hardwareProperties.udid) instead of this CoreDevice identifier.
            # If log collection fails, switch to hw.get('udid', d.get('identifier', '')).
            udid = d.get('identifier', '')
            if udid:
                print(udid)
                sys.exit(0)
    sys.exit(1)
except Exception as e:
    print(f'Error parsing device list: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

    if [ -z "$udid" ]; then
        echo "Error: No wired iOS device found." >&2
        echo "  Ensure your iPhone is connected via USB and trusted." >&2
        echo "  Verify with: xcrun devicectl list devices" >&2
        return 1
    fi
    echo "$udid"
}

# Install an .app bundle on a physical iOS device.
# Uses `xcrun devicectl device install app` (Xcode 15+).
#
# Arguments:
#   $1 - device_udid  UDID of the target device
#   $2 - app_path     Path to the .app bundle directory
#
# Returns:
#   0 - App installed successfully
#   1 - Installation failed
#
# Usage: install_app_on_device "$DEVICE_UDID" "$APP_BUNDLE"
install_app_on_device() {
    local device_udid="$1"
    local app_path="$2"

    if [ -z "$device_udid" ]; then
        echo "Error: device UDID is required." >&2
        return 1
    fi
    if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
        echo "Error: app bundle path '$app_path' does not exist or is not a directory." >&2
        return 1
    fi

    xcrun devicectl device install app --device "$device_udid" "$app_path" 2>&1
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Error: Failed to install app on device $device_udid (exit code $exit_code)." >&2
        return 1
    fi
    return 0
}

# Launch an app on a physical iOS device.
# Uses `xcrun devicectl device process launch` (Xcode 15+).
# Terminates any existing instance of the app before launching.
#
# On success, prints the launched process PID to stdout. The caller can
# capture it and later pass it to terminate_app_on_device() for reliable
# termination (devicectl terminate requires --pid, not bundle ID).
#
# Arguments:
#   $1 - device_udid  UDID of the target device
#   $2 - bundle_id    Bundle identifier of the app (e.g., "com.companyname.myapp")
#
# Output (stdout): PID of the launched process (integer), or empty if PID
#                  could not be parsed (launch still succeeded).
#
# Returns:
#   0 - App launched successfully
#   1 - Launch failed
#
# Usage:
#   APP_PID=$(launch_app_on_device "$DEVICE_UDID" "$BUNDLE_ID")
#   # ... measure ...
#   terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID" "$APP_PID"
launch_app_on_device() {
    local device_udid="$1"
    local bundle_id="$2"

    if [ -z "$device_udid" ]; then
        echo "Error: device UDID is required." >&2
        return 1
    fi
    if [ -z "$bundle_id" ]; then
        echo "Error: bundle ID is required." >&2
        return 1
    fi

    # Use --json-output to reliably extract the PID of the launched process.
    # The text output format varies across Xcode versions, but JSON is stable.
    local json_file
    json_file=$(mktemp /tmp/devicectl_launch.XXXXXX.json)

    local launch_output
    launch_output=$(xcrun devicectl device process launch \
        --terminate-existing \
        --device "$device_udid" \
        --json-output "$json_file" \
        "$bundle_id" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "Error: Failed to launch $bundle_id on device $device_udid (exit code $exit_code)." >&2
        echo "  $launch_output" >&2
        rm -f "$json_file"
        return 1
    fi

    # Extract PID from JSON output. The structure is:
    #   { "result": { "process": { "processIdentifier": <pid>, ... } } }
    # Fall back to text parsing if JSON fails.
    local pid=""
    if [ -f "$json_file" ]; then
        pid=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    pid = data.get('result', {}).get('process', {}).get('processIdentifier')
    if pid is not None:
        print(int(pid))
except Exception:
    pass
" "$json_file" 2>/dev/null)
    fi

    rm -f "$json_file"

    # If JSON parsing failed, try to extract PID from text output.
    # Known patterns: "Launched process <PID>" or "pid: <PID>"
    if [ -z "$pid" ] && [ -n "$launch_output" ]; then
        pid=$(echo "$launch_output" | grep -oE '[Pp]rocess ([Ii]dentifier: |)[0-9]+' | grep -oE '[0-9]+' | tail -1)
    fi

    if [ -n "$pid" ]; then
        echo "$pid"
    fi
    return 0
}

# Terminate a running app on a physical iOS device.
# Best-effort — does not fail if the app is not running or termination fails.
#
# When a PID is provided (captured from launch_app_on_device), uses
# `xcrun devicectl device process terminate --pid <PID>` for reliable
# termination. Without a PID, this is a no-op since devicectl terminate
# does not support bundle-ID-based termination.
#
# Arguments:
#   $1 - device_udid  UDID of the target device
#   $2 - bundle_id    Bundle identifier of the app (for logging only)
#   $3 - pid          (optional) Process ID from launch_app_on_device
#
# Returns:
#   0 - Always (best-effort cleanup)
#
# Usage: terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID" "$APP_PID"
terminate_app_on_device() {
    local device_udid="$1"
    local bundle_id="$2"
    local pid="$3"

    if [ -z "$device_udid" ]; then
        return 0  # nothing to do
    fi

    # With a valid PID, we can reliably terminate the process
    if [ -n "$pid" ]; then
        xcrun devicectl device process terminate \
            --device "$device_udid" --pid "$pid" 2>/dev/null || true
    fi
    # Without a PID, we can't do anything — devicectl terminate requires --pid.
    # The next launch with --terminate-existing or uninstall will clean up.
    return 0
}

# Uninstall an app from a physical iOS device.
# Best-effort cleanup — does not fail if the app is not installed.
#
# Arguments:
#   $1 - device_udid  UDID of the target device
#   $2 - bundle_id    Bundle identifier of the app
#
# Returns:
#   0 - Always (best-effort cleanup)
#
# Usage: uninstall_app_from_device "$DEVICE_UDID" "$BUNDLE_ID"
uninstall_app_from_device() {
    local device_udid="$1"
    local bundle_id="$2"

    if [ -z "$device_udid" ] || [ -z "$bundle_id" ]; then
        return 0  # nothing to do
    fi

    xcrun devicectl device uninstall app --device "$device_udid" "$bundle_id" 2>/dev/null || true
    return 0
}

# =============================================================================
# Process detection
# =============================================================================

# Wait for a process with the given name to appear.
# Uses pgrep to find the process. Returns the PID on stdout when found.
#
# Arguments:
#   $1 - process_name  Name to match (passed to pgrep -x for exact match)
#   $2 - timeout       Maximum seconds to wait (default: 30)
#   $3 - poll_interval Seconds between polls (default: 0.05 = 50ms)
#
# Returns:
#   0 - Process found (PID printed to stdout)
#   1 - Timeout
#
# Usage: pid=$(wait_for_process "MyApp" 10)
wait_for_process() {
    local process_name="$1"
    local timeout="${2:-30}"
    local poll_interval="${3:-0.05}"
    local deadline=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$deadline" ]; do
        local pid
        pid=$(pgrep -x "$process_name" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
        sleep "$poll_interval"
    done

    return 1  # timeout
}

# =============================================================================
# Statistics computation
# =============================================================================

# Compute statistics from an array of timing values.
# Outputs 6 lines: avg, median, min, max, stdev, count
# Numeric values are formatted to 2 decimal places; count is an integer.
#
# Requires at least 1 value. Stdev is 0.00 for a single value.
#
# Arguments:
#   $@ - Timing values (e.g., "150.23" "200.45" "175.80")
#
# Usage:
#   STATS=$(compute_stats "${TIMES[@]}")
#   AVG=$(echo "$STATS" | sed -n '1p')
#   MEDIAN=$(echo "$STATS" | sed -n '2p')
#   MIN=$(echo "$STATS" | sed -n '3p')
#   MAX=$(echo "$STATS" | sed -n '4p')
#   STDEV=$(echo "$STATS" | sed -n '5p')
#   COUNT=$(echo "$STATS" | sed -n '6p')
compute_stats() {
    if [ $# -eq 0 ]; then
        echo "Error: compute_stats requires at least one value." >&2
        return 1
    fi

    # Build a comma-separated string from the arguments.
    # This avoids the fragile ${TIMES[0]}$(printf ...) pattern used
    # in the original scripts, and handles edge cases safely.
    local times_str=""
    local first=true
    for t in "$@"; do
        if [ "$first" = true ]; then
            times_str="$t"
            first=false
        else
            times_str="$times_str, $t"
        fi
    done

    python3 << PYEOF
import statistics
times = [$times_str]
times.sort()
n = len(times)
avg = statistics.mean(times)
median = statistics.median(times)
min_t = min(times)
max_t = max(times)
stdev = statistics.stdev(times) if n > 1 else 0.0
print(f'{avg:.2f}')
print(f'{median:.2f}')
print(f'{min_t:.2f}')
print(f'{max_t:.2f}')
print(f'{stdev:.2f}')
print(f'{n}')
PYEOF
}

# =============================================================================
# Build time measurement (binlog parsing)
# =============================================================================

# Run test.py buildtime to parse build metrics from an MSBuild binlog.
#
# Uses the dotnet/performance infrastructure to extract per-task build timing
# (ILLink, MonoAOTCompiler, AppleAppBuilderTask, AndroidAppBuilderTask) and
# total Publish Time from a binary log produced by `dotnet build -bl:`.
#
# Outputs a "Build time: XXXX.XX ms" line to stdout on success.
# Also outputs the detailed per-task breakdown from test.py for visibility.
# On failure, prints a warning and outputs nothing parseable — the caller
# can fall back to wall-clock timing.
#
# Requirements:
#   - DOTNET_ROOT must be set (or DOTNET_DIR from init.sh)
#   - python3 must be available
#   - The external/performance submodule must be checked out
#
# Arguments:
#   $1 - binlog_path     Absolute path to the .binlog file
#   $2 - scenario_name   Name for the scenario (e.g., "dotnet-new-macos_CORECLR_JIT")
#
# Usage:
#   BUILDTIME_OUTPUT=$(run_buildtime_parser "$BINLOG_PATH" "${SAMPLE_APP}_${BUILD_CONFIG}")
#   echo "$BUILDTIME_OUTPUT"
run_buildtime_parser() {
    local binlog_path="$1"
    local scenario_name="$2"

    # Validate inputs
    if [ -z "$binlog_path" ] || [ ! -f "$binlog_path" ]; then
        echo "Warning: Binlog not found at '$binlog_path', skipping build time parsing." >&2
        return 1
    fi

    if [ -z "$scenario_name" ]; then
        echo "Warning: scenario_name is required for build time parsing." >&2
        return 1
    fi

    # Locate the test.py script in the dotnet/performance submodule.
    # We use genericandroidstartup as the scenario directory because the
    # buildtime codepath in runner.py ignores the scenario's EXENAME —
    # it unconditionally sets apptorun="app". Any scenario dir works.
    local perf_dir="${PERF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/external/performance}"
    local scenario_dir="$perf_dir/src/scenarios/genericandroidstartup"
    local test_py="$scenario_dir/test.py"

    if [ ! -f "$test_py" ]; then
        echo "Warning: test.py not found at '$test_py'. Is the external/performance submodule checked out?" >&2
        return 1
    fi

    # Ensure DOTNET_ROOT is set for the Startup tool build
    local dotnet_dir="${DOTNET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.dotnet}"
    export DOTNET_ROOT="${DOTNET_ROOT:-$dotnet_dir}"
    export PATH="$DOTNET_ROOT:$PATH"

    # Ensure PYTHONPATH includes the scenarios dir (for shared.runner import)
    local scenarios_dir="${SCENARIOS_DIR:-$perf_dir/src/scenarios}"
    export PYTHONPATH="$scenarios_dir:${PYTHONPATH:-}"

    # The runner expects the binlog at traces/<binlog-path> relative to CWD.
    # Create traces/ in the scenario dir and copy the binlog there.
    local binlog_filename
    binlog_filename=$(basename "$binlog_path")

    local traces_dir="$scenario_dir/traces"
    mkdir -p "$traces_dir"
    cp "$binlog_path" "$traces_dir/$binlog_filename"

    # Run test.py buildtime from the scenario directory
    local output
    local exit_code
    output=$(cd "$scenario_dir" && python3 test.py buildtime \
        --scenario-name "$scenario_name" \
        --binlog-path "./$binlog_filename" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    # Clean up: remove the copied binlog to avoid accumulation
    rm -f "$traces_dir/$binlog_filename"

    if [ $exit_code -ne 0 ]; then
        echo "Warning: test.py buildtime failed (exit code $exit_code). Build time parsing unavailable." >&2
        echo "$output" | tail -5 >&2
        return 1
    fi

    # Echo the full output for visibility (detailed per-task breakdown)
    echo "$output"

    # Parse "Publish Time" from the result table.
    # Format: "Publish Time   |42.123 s       |42.123 s       |42.123 s"
    local publish_time_s
    publish_time_s=$(echo "$output" | grep "Publish Time" | awk -F'|' '{print $2}' | sed 's/[^0-9.]//g')

    if [ -n "$publish_time_s" ]; then
        # Convert seconds to milliseconds
        local build_time_ms
        build_time_ms=$(python3 -c "print(f'{float(\"$publish_time_s\") * 1000:.2f}')")
        echo "Build time: ${build_time_ms} ms"
    else
        echo "Warning: Could not parse Publish Time from test.py buildtime output." >&2
        return 1
    fi

    return 0
}

# =============================================================================
# Output formatting
# =============================================================================

# Print the parseable summary lines expected by measure_all.sh.
# Format:
#   Generic Startup | <avg> | <min> | <max>
#   APP size: <size_mb> MB (<size_bytes> bytes)
#
# Arguments:
#   $1 - avg         Average startup time in ms (e.g., "200.00")
#   $2 - min         Minimum startup time in ms
#   $3 - max         Maximum startup time in ms
#   $4 - size_mb     Package size in MB (e.g., "50.00")
#   $5 - size_bytes  Package size in bytes (e.g., "52428800")
#
# Usage: print_measurement_summary "$AVG" "$MIN" "$MAX" "$SIZE_MB" "$SIZE_BYTES"
print_measurement_summary() {
    local avg="$1"
    local min="$2"
    local max="$3"
    local size_mb="$4"
    local size_bytes="$5"

    echo "Generic Startup | ${avg} | ${min} | ${max}"
    echo "APP size: ${size_mb} MB ($size_bytes bytes)"
}

# =============================================================================
# CSV result saving
# =============================================================================

# Save detailed per-iteration results to a CSV file.
# The CSV contains one row per iteration plus a summary comment line.
#
# Arguments:
#   $1  - output_file   Path to the CSV file to write
#   $2  - sample_app    App name (e.g., "dotnet-new-macos")
#   $3  - build_config  Build config (e.g., "CORECLR_JIT")
#   $4  - platform      Platform label (e.g., "osx", "maccatalyst", "simulator")
#   $5  - size_mb       Package size in MB
#   $6  - size_bytes    Package size in bytes
#   $7  - avg           Average startup time in ms
#   $8  - median        Median startup time in ms
#   $9  - min_val       Minimum startup time in ms
#   $10 - max_val       Maximum startup time in ms
#   $11 - stdev         Standard deviation in ms
#   $12 - count         Number of successful iterations
#   $@  (remaining)     Per-iteration timing values
#
# Usage:
#   save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "osx" \
#       "$SIZE_MB" "$SIZE_BYTES" "$AVG" "$MEDIAN" "$MIN" "$MAX" "$STDEV" "$COUNT" \
#       "${TIMES[@]}"
save_results_csv() {
    local output_file="$1"
    local sample_app="$2"
    local build_config="$3"
    local platform="$4"
    local size_mb="$5"
    local size_bytes="$6"
    local avg="$7"
    local median="$8"
    local min_val="$9"
    local max_val="${10}"
    local stdev="${11}"
    local count="${12}"
    shift 12
    local times=("$@")

    {
        echo "iteration,time_ms"
        for ((idx = 0; idx < ${#times[@]}; idx++)); do
            echo "$((idx + 1)),${times[$idx]}"
        done
        echo ""
        echo "# summary: avg_ms,median_ms,min_ms,max_ms,stdev_ms,count,app,config,platform,pkg_size_mb,pkg_size_bytes"
        echo "$avg,$median,$min_val,$max_val,$stdev,$count,$sample_app,$build_config,$platform,$size_mb,$size_bytes"
    } > "$output_file"
}

# =============================================================================
# .nettrace trace collection helpers
# =============================================================================

# Default EventPipe providers for startup analysis.
# - Microsoft-Windows-DotNETRuntime with JIT, Loader, GC, R2R, TypeLoad events
# - Microsoft-DotNETCore-SampleProfiler for CPU sampling
NETTRACE_PROVIDERS="Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-DotNETCore-SampleProfiler:0x0:5"

# Set up EventPipe environment variables for trace collection.
# These are designed for the "simple" approach: env vars tell the runtime to
# write a .nettrace file on startup without needing dotnet-trace or dsrouter.
#
# Arguments:
#   $1 - output_path  Where to write the .nettrace file
#   $2 - providers    Provider config string (default: $NETTRACE_PROVIDERS)
#
# Sets the following environment variables in the CALLING shell:
#   DOTNET_EnableEventPipe=1
#   DOTNET_EventPipeOutputPath=<output_path>
#   DOTNET_EventPipeOutputStreaming=1
#   DOTNET_EventPipeConfig=<providers>
#
# Usage:
#   setup_eventpipe_env "/tmp/trace.nettrace"
#   # ... launch app with these env vars ...
#   unset_eventpipe_env
setup_eventpipe_env() {
    local output_path="$1"
    local providers="${2:-$NETTRACE_PROVIDERS}"

    export DOTNET_EnableEventPipe=1
    export DOTNET_EventPipeOutputPath="$output_path"
    export DOTNET_EventPipeOutputStreaming=1
    export DOTNET_EventPipeConfig="$providers"
}

# Unset EventPipe environment variables after trace collection.
# Safe to call even if setup_eventpipe_env was never called.
# Usage: unset_eventpipe_env
unset_eventpipe_env() {
    unset DOTNET_EnableEventPipe
    unset DOTNET_EventPipeOutputPath
    unset DOTNET_EventPipeOutputStreaming
    unset DOTNET_EventPipeConfig
}

# Collect the .nettrace file after an app run.
# Searches for .nettrace files at the expected path, and if not found,
# searches common locations (app data container, /tmp, etc.).
#
# Arguments:
#   $1 - expected_path  Where the trace should have been written
#   $2 - dest_path      Where to copy the trace file
#   $3 - search_dirs    (Optional) Space-separated list of additional dirs to search
#
# Returns:
#   0 - Trace file found and copied successfully
#   1 - No trace file found
#
# Usage:
#   collect_nettrace "/tmp/trace.nettrace" "$RESULTS_DIR/app_config.nettrace"
collect_nettrace() {
    local expected_path="$1"
    local dest_path="$2"
    local search_dirs="${3:-}"

    # First, check the expected path
    if [ -f "$expected_path" ]; then
        if validate_nettrace "$expected_path" 2>/dev/null; then
            local file_size
            file_size=$(wc -c < "$expected_path" | tr -d ' ')
            cp "$expected_path" "$dest_path"
            echo "Trace collected: $dest_path ($file_size bytes)"
            rm -f "$expected_path"
            return 0
        else
            echo "Warning: Trace file at $expected_path failed validation." >&2
        fi
    fi

    # Search additional directories for .nettrace files matching the expected name pattern.
    # Derive a scoped glob from the expected filename (strip PID suffix) to avoid matching
    # stale traces from previous runs.
    local expected_basename
    expected_basename=$(basename "$expected_path" .nettrace)
    # Strip trailing _<PID> (digits after last underscore) to get the app/config prefix
    local name_pattern
    name_pattern=$(echo "$expected_basename" | sed 's/_[0-9]*$//')

    for dir in $search_dirs; do
        if [ -d "$dir" ]; then
            local found
            found=$(find "$dir" -name "${name_pattern}*.nettrace" -size +1k 2>/dev/null | head -1)
            if [ -n "$found" ] && validate_nettrace "$found" 2>/dev/null; then
                local file_size
                file_size=$(wc -c < "$found" | tr -d ' ')
                cp "$found" "$dest_path"
                echo "Trace collected from $found: $dest_path ($file_size bytes)"
                rm -f "$found"
                return 0
            fi
        fi
    done

    echo "Warning: No .nettrace file found at expected path or search directories." >&2
    return 1
}

# Build the SIMCTL_CHILD_ prefixed env var exports for iOS Simulator trace collection.
# The iOS Simulator passes environment variables to launched apps when they
# have the SIMCTL_CHILD_ prefix.
#
# Arguments:
#   $1 - output_path  Where to write the .nettrace file (inside simulator container)
#   $2 - providers    Provider config string (default: $NETTRACE_PROVIDERS)
#
# Usage:
#   setup_simctl_eventpipe_env "/tmp/trace.nettrace"
#   xcrun simctl launch ...
#   unset_simctl_eventpipe_env
setup_simctl_eventpipe_env() {
    local output_path="$1"
    local providers="${2:-$NETTRACE_PROVIDERS}"

    export SIMCTL_CHILD_DOTNET_EnableEventPipe=1
    export SIMCTL_CHILD_DOTNET_EventPipeOutputPath="$output_path"
    export SIMCTL_CHILD_DOTNET_EventPipeOutputStreaming=1
    export SIMCTL_CHILD_DOTNET_EventPipeConfig="$providers"
}

# Unset SIMCTL_CHILD_ prefixed EventPipe environment variables.
# Usage: unset_simctl_eventpipe_env
unset_simctl_eventpipe_env() {
    unset SIMCTL_CHILD_DOTNET_EnableEventPipe
    unset SIMCTL_CHILD_DOTNET_EventPipeOutputPath
    unset SIMCTL_CHILD_DOTNET_EventPipeOutputStreaming
    unset SIMCTL_CHILD_DOTNET_EventPipeConfig
}
