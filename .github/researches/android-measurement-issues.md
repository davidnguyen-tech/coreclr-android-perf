# Android Measurement Issues Investigation

## Issue 1: `.trace` file produced, not `_device.csv`

### Architecture

The measurement flow has **two completely separate paths** that produce different output formats:

1. **`measure_startup.sh` → `test.py devicestartup` (Android path)**: Produces a `.trace` file
2. **`ios/measure_device_startup.sh` (iOS device path)**: Produces a `_device.csv` file

### Root Cause

**This is expected behavior, not a bug.** The Android path through `measure_startup.sh` was never designed to produce `_device.csv` files. The flow is:

```
measure_startup.sh (line 309)
  → python3 test.py devicestartup --device-type android ...
    → runner.py line 519-693 (Android devicestartup branch)
      → Runs adb am start-activity, parses logcat for "Displayed" time
      → Writes "TotalTime: <ms>\n" lines to traces/PerfTest/runoutput.trace
      → Calls StartupWrapper().parsetraces() which runs the Startup tool
      → Startup tool parses the .trace file and prints "Generic Startup" table to stdout
  → measure_startup.sh copies runoutput.trace to results/${NAME}.trace (line 319-321)
```

The `_device.csv` format is **only** produced by `ios/measure_device_startup.sh` (line 623-626), which uses the custom `save_results_csv()` function from `tools/apple_measure_lib.sh` (line 1034).

### Where results actually go

- **Raw data**: `results/dotnet-new-maui_MONO_JIT.trace` — contains `TotalTime: <ms>` lines
- **Parsed summary**: Printed to **stdout** by the Startup tool as a "Generic Startup" table (with avg/min/max)
- **Aggregated CSV**: `measure_all.sh` (line 168-170) parses the "Generic Startup" line from stdout to build `results/summary.csv`

The existing `results/dotnet-new-maui_MONO_JIT_device.csv` (with 340ms data from March 11) was created by a **different code path** — likely an older version of measure_startup.sh or a manual iOS measurement run. It is NOT updated by the current Android measurement flow.

### The 5× time difference (340ms vs 1836ms)

The old CSV shows 334-367ms (avg 340ms) while the new .trace shows 1836ms. Possible explanations:

1. **Different device**: Old measurements may have been taken on a faster device or emulator
2. **Different SDK/runtime version**: The .NET 11 preview SDK may have regressed compared to whatever was used in March
3. **Hot vs cold start**: The 340ms times look like warm/hot starts; 1836ms looks like a genuine cold start of a MAUI app with Mono JIT on a physical Android device
4. **Build config difference**: If the old measurement was accidentally run with a cached build from a different config

**The 1836ms value is actually plausible** for a cold-start MAUI app with Mono JIT on a physical Android device. MAUI apps are heavy (48MB APK per the CSV metadata), and Mono JIT has to JIT-compile everything at startup.

### Recommendation

No code fix needed for the `.trace` vs `.csv` format — they serve different purposes:
- `.trace` is the raw output from the dotnet/performance Startup tool pipeline
- `_device.csv` is a custom format from Apple platform scripts

If you want consistent CSV output for Android too, `measure_startup.sh` would need to be enhanced to parse the `.trace` file and call `save_results_csv()`. But `measure_all.sh` already handles the aggregation through stdout parsing.

---

## Issue 2: `dotnet restore --runtime osx-arm64` for Android target

### Root Cause

**This is NOT restoring the Android app.** It's restoring the **Startup parser tool** — a .NET console app that runs on the *host machine* (macOS) to parse measurement results.

The flow:

```
runner.py line 691: startup = StartupWrapper()
  → startup.py line 29-52: StartupWrapper.__init__()
    → If artifacts/startup/ doesn't exist yet:
      → startup.restore(packages_dir, True, getruntimeidentifier())     ← LINE 41-43
      → startup.publish('Release', ..., getruntimeidentifier(), ...)    ← LINE 44-52
```

`getruntimeidentifier()` in `util.py` (line 45-67) returns the **host machine's RID**:
- On macOS ARM64: `osx-arm64`
- On Linux x64: `linux-x64`
- On Windows: `win-x64`

**This is correct behavior.** The Startup tool must run on the host, so it needs the host RID. The `--runtime osx-arm64` is for building the parser tool, not the Android app.

### Why the restore failed

The restore failure is a **NuGet feed issue**, not a RID issue. The error `CalledProcessError: Command '$ dotnet restore ... --runtime osx-arm64' returned non-zero exit status 1` means the restore itself failed — likely because:

1. **Stale DARC feeds**: The `external/performance/NuGet.config` has many `darc-pub-*` feeds that may have expired or been garbage collected
2. **Network/auth issues**: `pkgs.dev.azure.com/dnceng` feeds may require authentication or the specific feed may no longer exist
3. **Missing NuGet.config context**: The Startup tool project (at `../../tools/ScenarioMeasurement/Startup/Startup.csproj`) may resolve a different NuGet.config than expected, since `dotnet restore` walks up the directory tree to find one

### Key Files

| File | Line | Purpose |
|------|------|---------|
| `measure_startup.sh` | 309-313 | Invokes `test.py devicestartup` with passthrough args |
| `measure_startup.sh` | 318-321 | Copies `runoutput.trace` to `results/` |
| `external/performance/src/scenarios/shared/runner.py` | 519-693 | Android `DEVICESTARTUP` flow |
| `external/performance/src/scenarios/shared/runner.py` | 681-693 | Writes trace file + invokes Startup tool |
| `external/performance/src/scenarios/shared/startup.py` | 28-53 | Builds Startup tool on first use |
| `external/performance/src/scenarios/shared/startup.py` | 41-43 | `dotnet restore --runtime <host-RID>` |
| `external/performance/src/scenarios/shared/util.py` | 45-67 | `getruntimeidentifier()` — returns host RID |
| `external/performance/scripts/dotnet.py` | 283-315 | `CSharpProject.restore()` runs `dotnet restore` |
| `ios/measure_device_startup.sh` | 623-626 | Creates `_device.csv` (iOS only) |
| `tools/apple_measure_lib.sh` | 1034-1058 | `save_results_csv()` function |
| `measure_all.sh` | 168-170 | Parses "Generic Startup" from stdout for `summary.csv` |

### Recommendation for Issue 2

1. **The RID is not wrong** — it's the host RID for building the Startup parser tool. No change needed.
2. **The NuGet failure** needs investigation into which specific packages failed to restore. Options:
   - Pre-build the Startup tool in `prepare.sh` so it's cached before measurement
   - Ensure the `external/performance/NuGet.config` has valid feeds (update the submodule)
   - Set `NUGET_PACKAGES` or `RestorePackagesPath` to a pre-populated cache
