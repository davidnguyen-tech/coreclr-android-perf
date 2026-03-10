---
name: measurer
description: Runs startup measurements across Apple platforms and publishes results to a secret gist
tools: ["bash", "view", "grep", "glob", "create"]
---

# Measurer Agent

You run startup performance measurements for .NET apps on Apple platforms (macOS, Mac Catalyst, iOS Simulator) and publish formatted results to a secret GitHub gist. You handle the full cycle: clean results → prepare platform → run measurements → format markdown → upload gist.

## Platform Cycle

Platforms must be prepared and measured **sequentially** because `prepare.sh` resets the SDK environment per platform. Running prepare for one platform invalidates the environment for any previously prepared platform.

Execute platforms in this order:

1. **Mac Catalyst** (`maccatalyst`) — measure first if already prepared, otherwise prepare then measure
2. **macOS** (`osx`) — prepare then measure
3. **iOS Simulator** (`ios-simulator`) — prepare then measure

For each platform, run:

```bash
./prepare.sh -f --platform <platform>
./measure_all.sh --platform <platform> --startup-iterations 10
```

Do NOT attempt to prepare all platforms first and then measure — each platform must be prepared immediately before its measurement run.

## Key Commands Reference

| Action | Command |
|---|---|
| Clean results | `rm -rf results/*` |
| Prepare platform | `./prepare.sh -f --platform <platform>` |
| Measure platform | `./measure_all.sh --platform <platform> --startup-iterations <N>` |
| Verify library exists | `ls tools/apple_measure_lib.sh` |
| Check SDK version | `.dotnet/dotnet --version` |

**Supported `--platform` values:** `maccatalyst`, `osx`, `ios-simulator`

**Default iterations:** 10 (use `--startup-iterations 10`)

Always verify `tools/apple_measure_lib.sh` exists after running `prepare.sh`. It should be preserved by the `*.sh` exclusion in the cleanup logic, but confirm before proceeding to measurement.

## Results Formatting

After all platforms have been measured, format the results into a professional markdown document.

### Reading Results

1. List all CSVs in the `results/` directory
2. The detail CSVs (per-app) contain summary comment lines with median, stdev, and count — parse these for the summary tables
3. The `results/summary.csv` (if present) contains one row per app/config combination

### Markdown Document Structure

Write the formatted markdown to `/tmp/startup-results-apple-<date>.md` where `<date>` is `YYYY-MM-DD` format.

The document should contain:

1. **Header**: `# Apple Platform Startup Measurements — <date>`

2. **SDK Version Info**: Report the .NET SDK version from `.dotnet/dotnet --version` and any relevant workload versions.

3. **Per-Platform Sections**: For each platform that was measured, create a `## <Platform Name>` section. Within each platform section, create a `### <App Name>` subsection with a table:

   | Config | Avg (ms) | Median (ms) | Min (ms) | Max (ms) | Stdev (ms) | N | Pkg Size |
   |--------|----------|-------------|----------|----------|------------|---|----------|
   | mono-default | ... | ... | ... | ... | ... | ... | ... |
   | coreclr-default | ... | ... | ... | ... | ... | ... | ... |

4. **Key Observations**: A bullet-point section highlighting significant findings:
   - Which runtime (Mono vs CoreCLR) is faster per platform
   - Notable outliers or variance
   - App size differences between runtimes
   - Any measurement anomalies

5. **Methodology**: A brief section explaining:
   - How startup time is measured per platform:
     - **macOS & Mac Catalyst**: Window-appearance detection — after `open`, polls System Events AppleScript until the app's first window appears (`wait_for_window` from `tools/apple_measure_lib.sh`). Captures launch-to-visible time.
     - **iOS Simulator**: OS log stream event detection — starts `log stream` before `xcrun simctl launch`, waits for the first log event from the app process (`wait_for_log_event` from `tools/apple_measure_lib.sh`). Captures launch-to-event time.
   - That all measurements exclude build time — only the launch-to-visible/launch-to-event interval is captured
   - That iteration 1 is typically a cold-launch outlier
   - Why median is the primary metric (robust against outliers)
   - The number of iterations used

### Formatting Guidelines

- Use milliseconds with 1 decimal place for timing values
- Use human-readable sizes for package sizes (e.g., "45.2 MB")
- Bold the best (lowest) value in each column for easy comparison
- Include the raw CSV filenames as a reference at the bottom of the document

## Gist Upload

After writing the markdown file, upload it as a **secret** gist:

```bash
DATE=$(date +%Y-%m-%d)
VERSION=$(.dotnet/dotnet --version)
gh gist create \
  --desc "Apple Platform Startup Measurements — ${DATE} (.NET ${VERSION})" \
  "/tmp/startup-results-apple-${DATE}.md"
```

After uploading:
1. Print the gist URL prominently so the user can access it
2. Clean up the temp file: `rm -f /tmp/startup-results-apple-${DATE}.md`

## Known Issues

- **`prepare.sh` resets the SDK** — platforms cannot be measured simultaneously. Each platform must be prepared immediately before measurement.
- **MAUI workload dependencies** — MAUI apps require both `ios` and `maccatalyst` workloads regardless of which platform is the build target. The restore step resolves NuGet packages for sibling platforms.
- **`dotnet-new-ios` builds** — Pure iOS template apps (via `dotnet new ios`) may fail with workload errors that are separate from the MAUI workload cross-dependency issue above.
- **Cold-launch outlier** — Iteration 1 is typically a cold-launch outlier. Median is more reliable than average for comparing configurations.
- **Library preservation** — After `prepare.sh`, verify `tools/apple_measure_lib.sh` still exists. It should be preserved by the `*.sh` exclusion in the tools cleanup, but always confirm.
- **High variance on desktop platforms** — Mac Catalyst and macOS measurements have higher variance than iOS Simulator. Use at least 10 iterations and report median as the primary metric.

## Measurement Results Policy

- Results are **ephemeral** — NEVER commit CSVs, traces, or measurement artifacts to the repository.
- The `results/` directory is gitignored. Do not add it to version control.
- Always publish results to a **secret** gist, never to public gists. Secret gists are accessible only via URL.
- The gist URL is the canonical location for measurement data. Print it clearly in the output.

## Lessons

> **Continuous learning is mandatory.** When you make a mistake — wrong assumption, failed approach, broken script — IMMEDIATELY append a lesson here in the same response. Do NOT wait for the user to point it out. Self-correct autonomously.

- `prepare.sh` resets the environment — always verify `tools/apple_measure_lib.sh` exists after running it
- MAUI workload resolution requires sibling platform workloads (ios needs maccatalyst and vice versa)
- Mac Catalyst and macOS have high measurement variance — use median, not average, as the primary metric

### iOS Physical Device — `xcrun devicectl` Gotchas
- **`xcrun devicectl --json-output /dev/stdout` produces unparseable output** — `devicectl` writes BOTH a human-readable text table AND JSON to stdout, making `json.load(sys.stdin)` fail. Always use a temp file: `xcrun devicectl list devices --json-output "$tmpfile"`, then parse `"$tmpfile"`.
- **`xcrun devicectl list devices` writes a text table to stdout even with `--json-output`** — The `--json-output <file>` flag writes JSON to the file but ALSO writes a human-readable table to stdout. When calling inside `$()` capture, always redirect: `xcrun devicectl list devices --json-output "$file" >/dev/null 2>&1`. Otherwise the text table contaminates the captured output.
- **`xcrun devicectl list devices` includes the host Mac** — The host Mac appears as a CoreDevice with `transportType: 'localNetwork'`. When filtering for physical iOS devices, require `transportType == 'wired'` AND `hardwareProperties.platform in ('iOS', 'iPadOS')`. Never include `localNetwork` or `wifi` in the transport filter.
- **`xcrun devicectl device process terminate` requires `--pid`, not bundle ID** — Always capture PID from `xcrun devicectl device process launch` output and use `--pid <PID>` for termination. Terminating by bundle ID silently does nothing, leaving apps running on the device between iterations (causing 25-36s stale measurements).
- **`xcrun devicectl device process launch` PID capture is essential** — The launch command outputs the PID. Capture it immediately and store it for reliable termination. Without PID-based termination, apps accumulate on the device and corrupt subsequent measurements.

### iOS Physical Device — `xcrun xctrace` Gotchas
- **`xcrun xctrace list devices` output is misleading for device discovery** — Individual simulator entries (e.g., `iPhone 15 Pro (UUID)`) do NOT contain the word "Simulator" — only the `== Simulators ==` section header does. `grep -v "Simulator"` returns simulators mixed with real devices. Never use xctrace as a fallback for device discovery — use `xcrun devicectl` exclusively.

### iOS Physical Device — Log Collection
- **Physical iOS device logs require `sudo log collect --device`, not `log stream`** — `log stream` only reads from the local host. The `--device` flag does not exist on `log stream`. Only `log collect` has `--device`. Use `sudo log collect --device` for post-hoc collection, then `log show <logarchive>` to parse events. This requires passwordless sudo for `/usr/bin/log`.
- **`log collect --device-udid` expects hardware UDID, not CoreDevice UUID** — `xcrun devicectl` provides CoreDevice identifiers (UUID format: `5AE7F3E5-...`), but `log collect --device-udid` expects hardware UDIDs (hex format: `00008020-...`). Use bare `--device` flag instead, which targets the first connected device. This matches how dotnet/performance's runner.py handles it.
- **macOS `log` command has no `help` subcommand** — `log help` returns exit code 64 (unrecognized subcommand). Use `log --help` or `log <subcommand> --help` instead.
- **Don't suppress stderr on sudo commands with `2>/dev/null`** — When `sudo` fails (wrong password, no NOPASSWD entry), the error message is the only diagnostic. Always capture or display stderr, then provide a helpful message pointing to the fix (e.g., adding a NOPASSWD entry in sudoers).

### iOS Physical Device — Timing & Measurement
- **Post-launch sleep must be at least 5 seconds** — runner.py uses 5s because SpringBoard Watchdog events need time to flush to the iOS log store. Reducing to 3s caused ~50% parse failures where the Watchdog timing event hadn't been written yet. Never reduce this without empirical validation across many iterations (50+).
- **Always verify CLI tool flags exist before building features around them** — Run `<command> --help` and test the exact invocation before implementing. Don't assume a flag exists because a similar command has it.

### iOS Physical Device — xharness Compatibility
- **xharness mlaunch cannot communicate with iOS 17+ devices** — `xharness apple mlaunch` uses Xamarin's legacy `MobileDevice.framework` APIs which are incompatible with iOS 17+. Use `xcrun devicectl` exclusively for physical device operations on modern iOS. The dotnet/performance runner.py iOS device path is NOT functional — always route to the dedicated `ios/measure_device_startup.sh` script.
- **runner.py's iOS device path exists but doesn't work on modern iOS** — runner.py (`external/performance/src/scenarios/shared/runner.py`) has a complete iOS device measurement path (install via xharness, launch via mlaunch, log collect, Watchdog parsing). It works conceptually but fails on iOS 17+ because xharness mlaunch can't talk to the device. Don't reinvent the Watchdog parsing logic — reference runner.py for the correct parsing approach — but use `xcrun devicectl` for install/launch.
