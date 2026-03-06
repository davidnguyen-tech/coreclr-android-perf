# .NET Mobile Performance Measurements

Repository for measuring startup performance, build times, and app sizes of .NET apps across **Android**, **iOS**, **macOS**, and **Mac Catalyst** using the [dotnet/performance](https://github.com/dotnet/performance) tooling.

## Prerequisites

- **.NET SDK** — version pinned in [`global.json`](./global.json) (currently `11.0.100-preview.3.26123.103`)
- **Python 3** (any supported 3.x version)
- **curl** (for downloading dotnet-install script and NuGet.config)
- **git** (for submodule initialization)

**Platform-specific requirements:**

| Requirement | Android | iOS | macOS | Mac Catalyst |
|---|---|---|---|---|
| Physical device (USB) | ✅ | ✅ | — | — |
| Xcode + command-line tools | — | ✅ | ✅ | ✅ |
| xharness | ✅ | ✅ | — | — |
| Passwordless `sudo` for `log collect` | — | ✅ | ✅ | ✅ |
| ADB (`adb devices -l`) | ✅ | — | — | — |

> **Apple platforms:** Startup measurement uses SpringBoard / system log timestamps. The `log collect` command requires `sudo`, and passwordless `sudo` is recommended to avoid interrupting automated measurement runs.

**Workloads installed by `prepare.sh`:**
- Android: `android`, `maui-android`
- iOS: `ios`, `maui-ios`
- macOS: `macos`, `maui-macos`
- Mac Catalyst: `maccatalyst`, `maui-maccatalyst`

## Quick Start

1. Clone the repo:

    ```bash
    git clone --recurse-submodules https://github.com/ivanpovazan/coreclr-android-perf.git
    cd ./coreclr-android-perf
    ```

2. Prepare the environment (pick your platform):

    ```bash
    # Android (default)
    ./prepare.sh

    # Apple platforms
    ./prepare.sh --platform ios
    ./prepare.sh --platform osx
    ./prepare.sh --platform maccatalyst
    ```

    This will:
    - Install the .NET SDK version pinned in `global.json` into `.dotnet/`
    - Install platform-specific workloads
    - Install the `xharness` CLI tool and diagnostic tools (`dotnet-dsrouter`, `dotnet-trace`)
    - Initialize the `dotnet/performance` submodule
    - Generate sample apps via `dotnet new` templates

3. Run startup measurements:

    ```bash
    # Single configuration
    ./measure_startup.sh dotnet-new-android R2R --platform android
    ./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios
    ./measure_startup.sh dotnet-new-macos R2R_COMP --platform osx
    ./measure_startup.sh dotnet-new-maui R2R_COMP_PGO --platform maccatalyst

    # All configurations for a platform
    ./measure_all.sh --platform ios --startup-iterations 10
    ```

4. Inspect results in `results/summary.csv` or the console output.

> **Note:** Pass `-f` to `prepare.sh` to force a full reset of the environment.

## Build Configuration Availability

| Config | Android | iOS | macOS | Mac Catalyst |
|---|---|---|---|---|
| MONO_JIT | ✅ | ✅ | ✅ | ✅ |
| MONO_AOT | ✅ | ✅ | ✅ | ✅ |
| MONO_PAOT | ✅ | ✅ | ✅ | ✅ |
| CORECLR_JIT | ✅ | ✅ | ✅ | ✅ |
| R2R | ✅ | ❌ | ❌ | ❌ |
| R2R_COMP | ✅ | ✅ | ✅ | ✅ |
| R2R_COMP_PGO | ✅ | ✅ | ✅ | ✅ |

> **Note:** Apple platforms use the Mach-O binary format, which only supports Composite ReadyToRun. Non-composite R2R (`R2R`) is available on Android only.

## Runtime Configurations

| Config | Runtime | Description |
|--------|---------|-------------|
| MONO_JIT | Mono | Mono with JIT enabled |
| MONO_AOT | Mono | Mono with full AOT |
| MONO_PAOT | Mono | Mono with profile-guided AOT |
| CORECLR_JIT | CoreCLR | CoreCLR with JIT only |
| R2R | CoreCLR | CoreCLR with ReadyToRun (Android only) |
| R2R_COMP | CoreCLR | CoreCLR with Composite ReadyToRun |
| R2R_COMP_PGO | CoreCLR | CoreCLR with Composite R2R + PGO profiles |

Configurations are defined per platform in `<platform>/build-configs.props` and imported via [`Directory.Build.props`](./Directory.Build.props).

## App Types

| App | Template | Android | iOS | macOS | Mac Catalyst |
|-----|----------|---------|-----|-------|--------------|
| `dotnet-new-android` | `dotnet new android` | ✅ | — | — | — |
| `dotnet-new-ios` | `dotnet new ios` | — | ✅ | — | — |
| `dotnet-new-macos` | `dotnet new macos` | — | — | ✅ | — |
| `dotnet-new-maui` | `dotnet new maui` | ✅ | ✅ | ✅ | ✅ |
| `dotnet-new-maui-samplecontent` | `dotnet new maui --sample-content` | ✅ | ✅ | ✅ | ✅ |

> **Note:** Mac Catalyst has no standalone `dotnet new` template — only MAUI apps are available.

## SDK Version Pinning

The .NET SDK version is pinned in [`global.json`](./global.json). To test against a different SDK build:

1. Edit `global.json` and update the `version` field
2. Run `./prepare.sh -f` to reinstall

## Workload Version Pinning

Workload versions can be pinned using [`rollback.json`](./rollback.json):

```bash
./prepare.sh -f -userollback --platform <platform>
```

## Performance Measurements

### Measuring Startup

```bash
./measure_startup.sh <app> <build-config> [options]
```

**Options:**
- `--platform <android|ios|osx|maccatalyst>` — Target platform (default: `android`)
- `--startup-iterations N` — Number of startup iterations (default: 10)
- `--disable-animations` — Disable device animations during measurement
- `--use-fully-drawn-time` — Use fully drawn time instead of displayed time
- `--fully-drawn-extra-delay N` — Extra delay for fully drawn time (seconds)
- `--trace-perfetto` — Capture a perfetto trace after measurements

Results are saved to `results/<app>_<config>.trace`.

**Examples:**

```bash
# Android: R2R startup of dotnet new android
./measure_startup.sh dotnet-new-android R2R --platform android

# iOS: CoreCLR JIT startup on physical device
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios

# macOS: Composite R2R with PGO
./measure_startup.sh dotnet-new-macos R2R_COMP_PGO --platform osx

# Mac Catalyst: Mono AOT on MAUI app
./measure_startup.sh dotnet-new-maui MONO_AOT --platform maccatalyst
```

### Measuring All Configurations

```bash
./measure_all.sh [options]
```

Runs `measure_startup.sh` for all (app, config) combinations and produces a summary table and CSV.

**Options:**
- `--platform <android|ios|osx|maccatalyst>` — Target platform (default: `android`)
- `--app <name>` — Measure only this app (can be repeated)
- `--startup-iterations N` — Iterations per config (default: 10)

**Output:** `results/summary.csv` with columns: app, config, avg_ms, min_ms, max_ms, pkg_size_mb, pkg_size_bytes, iterations.

**Examples:**

```bash
# All Android configurations with 10 iterations each
./measure_all.sh --platform android

# iOS: quick sweep with 3 iterations
./measure_all.sh --platform ios --startup-iterations 3

# macOS: only the standalone app, all configs
./measure_all.sh --platform osx --app dotnet-new-macos

# Mac Catalyst: all MAUI apps
./measure_all.sh --platform maccatalyst
```

### Collecting .nettrace Startup Traces

Each platform has a `collect_nettrace.sh` script that captures detailed runtime event traces (JIT compilation, assembly loading, GC, exceptions, thread pool, interop) for analyzing startup behavior.

```bash
# Android — uses dotnet-dsrouter to bridge diagnostics over ADB
./android/collect_nettrace.sh <app> <build-config> [options]

# iOS — uses dotnet-dsrouter to bridge diagnostics over USB
./ios/collect_nettrace.sh <app> <build-config> [options]

# macOS — runs locally, no device bridge needed
./osx/collect_nettrace.sh <app> <build-config> [options]

# Mac Catalyst — runs locally, no device bridge needed
./maccatalyst/collect_nettrace.sh <app> <build-config> [options]
```

**Common options:**
- `--duration N` — Trace duration in seconds (default: 60)
- `--force` — Re-collect even if a trace already exists

**Platform-specific options:**
- Android: `--pgo-instrumentation` — Include PGO instrumentation env vars
- iOS: `--device-id UDID` — Target device UDID (auto-detected if only one device)

**Output:** `traces/<app>_<config>/<platform>-startup.nettrace`

The trace directory also contains a build binlog and system/device logs for diagnostics.

**Event providers captured:**
- `Microsoft-Windows-DotNETRuntime` — JIT, Loader, GC, Exception, ThreadPool, Interop events
- `Microsoft-Windows-DotNETRuntimePrivate` — Additional runtime internals

**Analyzing traces:**
- **PerfView** (Windows) — Open the `.nettrace` file directly for rich event analysis
- **`dotnet-trace convert`** — Convert to speedscope format (`dotnet-trace convert <file>.nettrace --format Speedscope`) and open in [speedscope.app](https://www.speedscope.app/)
- **`dotnet-trace report`** — Generate summary reports from the command line

**Examples:**

```bash
# Android: Collect a CoreCLR R2R trace with default 60s duration
./android/collect_nettrace.sh dotnet-new-android R2R

# iOS: Collect a Mono JIT trace with 30s duration
./ios/collect_nettrace.sh dotnet-new-ios MONO_JIT --duration 30

# macOS: Collect a Composite R2R trace
./osx/collect_nettrace.sh dotnet-new-macos R2R_COMP --duration 30

# Mac Catalyst: Re-collect an existing trace
./maccatalyst/collect_nettrace.sh dotnet-new-maui R2R_COMP_PGO --force
```

### Building / Running Sample Apps Manually

```bash
./build.sh --platform <platform> <app> <build-config> <build|run> <ntimes> [additional_args]
```

**Examples:**

```bash
# Build dotnet new android with Mono JIT
./build.sh --platform android dotnet-new-android MONO_JIT build 1

# Build dotnet new ios with CoreCLR JIT
./build.sh --platform ios dotnet-new-ios CORECLR_JIT build 1

# Build dotnet new macos with Composite R2R
./build.sh --platform osx dotnet-new-macos R2R_COMP build 1

# Build MAUI app for Mac Catalyst
./build.sh --platform maccatalyst dotnet-new-maui R2R_COMP_PGO build 1
```

Build artifacts are copied to `./build/` for further inspection (APKs, `.app` bundles, binlogs).

### Measuring Package Sizes

```bash
# Android: APK sizes
./android/print_apk_sizes.sh [-unzipped]

# Apple platforms: .app bundle sizes
./ios/print_app_sizes.sh
./osx/print_app_sizes.sh
./maccatalyst/print_app_sizes.sh
```

## Platform-Specific Notes

### Android

- Standard setup — all 7 build configurations supported (including non-composite `R2R`)
- Requires a physical device or emulator visible via `adb devices -l`
- Apps: `dotnet-new-android`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*-Signed.apk` (single file)

### iOS

- Requires a physical iOS device connected via USB
- Uses `xharness` for device deployment and app management
- 6 build configurations (no non-composite R2R)
- Apps: `dotnet-new-ios`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*.app` bundle (directory)

### macOS

- Runs locally on the Mac — no external device needed
- 6 build configurations (no non-composite R2R)
- Apps: `dotnet-new-macos`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*.app` bundle (directory)

### Mac Catalyst

- MAUI-only — no standalone `dotnet new` template exists for Mac Catalyst
- Runs locally on the Mac — no external device needed
- 6 build configurations (no non-composite R2R)
- Apps: `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*.app` bundle (directory)

## Cleaning Builds

```bash
./clean.sh <all|APP_NAME>
```

Cleans build artifacts (`bin/`, `obj/`, binlogs) for the specified app or all apps.

## Project Structure

```
├── global.json               # SDK version pinning
├── rollback.json              # Workload version pinning
├── Directory.Build.props      # Shared build props — imports platform-specific configs
├── Directory.Build.targets    # Shared build targets — imports platform-specific workarounds
├── init.sh                    # Common helpers (platform resolution, paths)
├── prepare.sh                 # Environment setup (SDK, workloads, xharness, apps)
├── generate-apps.sh           # Dynamic sample app generation (--platform aware)
├── build.sh                   # Build/run sample apps (--platform aware)
├── measure_startup.sh         # Startup measurement (--platform aware)
├── measure_all.sh             # Run all configurations (--platform aware)
├── clean.sh                   # Clean build artifacts
├── dotnet-local.sh            # Proxy to local .NET SDK
├── android/                   # Android-specific files
│   ├── build-configs.props    #   Build configs (7 configs incl. R2R)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (via dsrouter + ADB)
│   ├── print_apk_sizes.sh    #   APK size reporting
│   ├── env.txt                #   DiagnosticPorts config for profiling
│   └── env-nettrace.txt       #   PGO instrumentation env vars
├── ios/                       # iOS-specific files
│   ├── build-configs.props    #   Build configs (6 configs, composite R2R only)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (via dsrouter + USB)
│   └── print_app_sizes.sh    #   .app bundle size reporting
├── osx/                       # macOS-specific files
│   ├── build-configs.props    #   Build configs (6 configs, composite R2R only)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (local, no dsrouter)
│   └── print_app_sizes.sh    #   .app bundle size reporting
├── maccatalyst/               # Mac Catalyst-specific files
│   ├── build-configs.props    #   Build configs (6 configs, composite R2R only)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (local, no dsrouter)
│   └── print_app_sizes.sh    #   .app bundle size reporting
├── profiles/                  # Shared PGO .mibc profiles
├── external/performance/      # dotnet/performance submodule
├── apps/                      # Generated sample apps (gitignored)
├── .dotnet/                   # Local .NET SDK install (gitignored)
├── build/                     # Build artifacts (gitignored)
├── traces/                    # Collected .nettrace traces (gitignored)
├── results/                   # Measurement results (gitignored)
└── tools/                     # Tools (dotnet-install.sh, xharness) (gitignored)
```
