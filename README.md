# .NET Mobile Performance Measurements

Repository for measuring startup performance, build times, and app sizes of .NET mobile apps using the [dotnet/performance](https://github.com/dotnet/performance) tooling. Currently supports **Android**, with **iOS** support planned.

## Prerequisites

- **Python 3** (any supported 3.x version)
- **curl** (for downloading dotnet-install script and NuGet.config)
- **git** (for submodule initialization)
- **Android:** device (developer mode enabled) or emulator, visible via `adb devices -l`
- **iOS:** iPhone (developer mode enabled) connected via USB, Xcode with command-line tools. Requires a passwordless sudoers entry for `log collect` — see [`ios/README.md`](./ios/README.md) for setup instructions

## Quick Start

1. Clone the repo:

    ```bash
    git clone --recurse-submodules https://github.com/ivanpovazan/coreclr-android-perf.git
    cd ./coreclr-android-perf
    ```

2. Prepare the environment:

    ```bash
    ./prepare.sh
    ```

    This will:
    - Install the .NET SDK version pinned in `global.json` into `.dotnet/`
    - Install Android and MAUI workloads
    - Install the `xharness` CLI tool
    - Initialize the `dotnet/performance` submodule
    - Generate sample apps via `dotnet new` templates

3. Run startup measurements:

    ```bash
    # Single configuration (android is the default platform)
    ./measure_startup.sh dotnet-new-android R2R

    # Explicit platform
    ./measure_startup.sh dotnet-new-android R2R --platform android

    # All configurations
    ./measure_all.sh --startup-iterations 10
    ```

4. Inspect results in `results/summary.csv` or the console output.

> **Note:** Pass `-f` to `prepare.sh` to force a full reset of the environment.

## SDK Version Pinning

The .NET SDK version is pinned in [`global.json`](./global.json). To test against a different SDK build:

1. Edit `global.json` and update the `version` field
2. Run `./prepare.sh -f` to reinstall

## Workload Version Pinning

Workload versions can be pinned using [`rollback.json`](./rollback.json):

```bash
./prepare.sh -f -userollback
```

## Performance Measurements

### Measuring Startup

```bash
./measure_startup.sh <app> <build-config> [options]
```

**Apps:** `dotnet-new-android`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`

**Build configs:** `MONO_JIT`, `CORECLR_JIT`, `MONO_AOT`, `MONO_PAOT`, `R2R`, `R2R_COMP`, `R2R_COMP_PGO`

**Options:**
- `--platform <android|ios>` — Target platform (default: `android`; iOS coming soon)
- `--startup-iterations N` — Number of startup iterations (default: 10)
- `--disable-animations` — Disable device animations during measurement
- `--use-fully-drawn-time` — Use fully drawn time instead of displayed time
- `--fully-drawn-extra-delay N` — Extra delay for fully drawn time (seconds)
- `--trace-perfetto` — Capture a perfetto trace after measurements

Results are saved to `results/<app>_<config>.trace`.

**Examples:**

```bash
# R2R startup of dotnet new android
./measure_startup.sh dotnet-new-android R2R

# Mono JIT startup of MAUI app with animations disabled
./measure_startup.sh dotnet-new-maui MONO_JIT --disable-animations

# R2R Composite with PGO
./measure_startup.sh dotnet-new-maui-samplecontent R2R_COMP_PGO
```

### Measuring All Configurations

```bash
./measure_all.sh [options]
```

Runs `measure_startup.sh` for all (app, config) combinations and produces a summary table and CSV.

**Options:**
- `--platform <name>` — Target platform: `android`, `ios` (default: `android`)
- `--app <name>` — Measure only this app (can be repeated)
- `--startup-iterations N` — Iterations per config (default: 10)

**Output:** `results/summary.csv` with columns: app, config, avg_ms, min_ms, max_ms, pkg_size_mb, pkg_size_bytes, iterations.

**Examples:**

```bash
# All configurations with 10 iterations each
./measure_all.sh

# Quick sweep with 3 iterations
./measure_all.sh --startup-iterations 3

# Only Android app, all configs
./measure_all.sh --app dotnet-new-android
```

### Collecting .nettrace Startup Traces (Android)

```bash
./android/collect_nettrace.sh <app> <build-config> [options]
```

Collects a `.nettrace` startup trace for a given (app, build-config) combination. The trace captures detailed runtime events (JIT compilation, assembly loading, GC, exceptions, thread pool, interop) that can be used to analyze startup behavior.

**Flow:**

1. Starts `dotnet-dsrouter` to bridge diagnostics from the Android device to the host
2. Builds and deploys the app with diagnostics enabled (`AndroidEnableProfiler=true`)
3. Runs `dotnet-trace collect` against the diagnostic port for the specified duration
4. Cleans up (stops dsrouter, uninstalls app from device)

**Options:**
- `--duration N` — Trace duration in seconds (default: 60)
- `--force` — Re-collect even if a trace already exists
- `--pgo-instrumentation` — Include PGO instrumentation env vars for higher-quality traces

**Output:** `traces/<app>_<config>/android-startup.nettrace`

The trace directory also contains the build binlog and a `logcat.txt` dump for diagnostics.

**Event providers captured:**
- `Microsoft-Windows-DotNETRuntime` — JIT, Loader, GC, Exception, ThreadPool, Interop events
- `Microsoft-Windows-DotNETRuntimePrivate` — Additional runtime internals

**Analyzing traces:**
- **PerfView** (Windows) — Open the `.nettrace` file directly for rich event analysis
- **`dotnet-trace convert`** — Convert to speedscope format (`dotnet-trace convert android-startup.nettrace --format Speedscope`) and open in [speedscope.app](https://www.speedscope.app/)
- **`dotnet-trace report`** — Generate summary reports from the command line

**Examples:**

```bash
# Collect a CoreCLR R2R trace with default 60s duration
./android/collect_nettrace.sh dotnet-new-android R2R

# Collect a Mono JIT trace with 30s duration
./android/collect_nettrace.sh dotnet-new-maui MONO_JIT --duration 30

# Re-collect an existing trace with PGO instrumentation
./android/collect_nettrace.sh dotnet-new-maui-samplecontent R2R_COMP_PGO --force --pgo-instrumentation
```

### Building / Running Sample Apps Manually

```bash
./build.sh <app> <build-config> <build|run> <ntimes> [additional_args]
```

**Examples:**

```bash
# Build dotnet new android with Mono JIT
./build.sh dotnet-new-android MONO_JIT build 1

# Run dotnet new maui with R2R + marshal methods
./build.sh dotnet-new-maui R2R run 1 "-p:AndroidEnableMarshalMethods=true"
```

Build artifacts are copied to `./build/` for further inspection (APKs, binlogs).

### Measuring APK Sizes (Android)

```bash
./android/print_apk_sizes.sh [-unzipped]
```

Scans the `./build/` directory for signed APKs and prints their sizes. Pass `-unzipped` to unpack and show extracted sizes.

## Runtime Configurations

| Config | Runtime | Description |
|--------|---------|-------------|
| MONO_JIT | Mono | Mono with JIT enabled |
| MONO_AOT | Mono | Mono with full AOT |
| MONO_PAOT | Mono | Mono with profile-guided AOT |
| CORECLR_JIT | CoreCLR | CoreCLR with JIT only |
| R2R | CoreCLR | CoreCLR with ReadyToRun |
| R2R_COMP | CoreCLR | CoreCLR with Composite ReadyToRun |
| R2R_COMP_PGO | CoreCLR | CoreCLR with Composite R2R + PGO profiles |

Configurations are defined in [`Directory.Build.props`](./Directory.Build.props).

## Cleaning Builds

```bash
./clean.sh <all|dotnet-new-android|dotnet-new-maui|dotnet-new-maui-samplecontent>
```

## Project Structure

```
├── global.json              # SDK version pinning
├── rollback.json             # Workload version pinning
├── Directory.Build.props     # Shared build configuration presets
├── Directory.Build.targets   # Shared build targets
├── init.sh                   # Common helpers (platform resolution, paths)
├── prepare.sh                # Environment setup (SDK, workloads, xharness, apps)
├── generate-apps.sh          # Dynamic sample app generation
├── build.sh                  # Build/run sample apps (--platform aware)
├── measure_startup.sh        # Startup measurement (--platform aware)
├── measure_all.sh            # Run all configurations (--platform aware)
├── clean.sh                  # Clean build artifacts
├── dotnet-local.sh           # Proxy to local .NET SDK
├── android/                  # Android-specific files
│   ├── build-configs.props   # Android build configuration presets
│   ├── build-workarounds.targets # Android build workarounds (R2R, etc.)
│   ├── collect_nettrace.sh   # .nettrace startup trace collection
│   ├── print_apk_sizes.sh    # APK size reporting
│   ├── env.txt               # DiagnosticPorts config for profiling
│   └── env-nettrace.txt      # PGO instrumentation env vars for trace collection
├── ios/                      # iOS-specific files (placeholder)
│   └── README.md             # iOS support roadmap
├── profiles/                 # Shared PGO .mibc profiles
├── external/performance/     # dotnet/performance submodule
├── apps/                     # Generated sample apps (gitignored)
├── .dotnet/                  # Local .NET SDK install (gitignored)
├── build/                    # Build artifacts (gitignored)
├── traces/                   # Collected .nettrace traces (gitignored)
├── results/                  # Measurement results (gitignored)
└── tools/                    # Tools (dotnet-install.sh, xharness) (gitignored)
```
