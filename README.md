# .NET Mobile Performance Measurements

Repository for measuring startup performance, build times, and app sizes of .NET apps across **Android**, **iOS**, **macOS**, and **Mac Catalyst** using the [dotnet/performance](https://github.com/dotnet/performance) tooling.

Supports both physical devices and **emulators/simulators** for development and relative comparison workflows.

## Prerequisites

- **.NET SDK** — version pinned in [`global.json`](./global.json) (currently `11.0.100-preview.3.26123.103`)
- **Python 3** (any supported 3.x version)
- **curl** (for downloading dotnet-install script)
- **git** (for submodule initialization)

**Platform-specific requirements:**

| Requirement | Android | Android Emulator | iOS | iOS Simulator | macOS | Mac Catalyst |
|---|---|---|---|---|---|---|
| Physical device (USB) | ✅ | — | ✅ | — | — | — |
| Emulator / Simulator | — | ✅ (`adb`) | — | ✅ (`xcrun simctl`) | — | — |
| Xcode + command-line tools | — | — | ✅ | ✅ | ✅ | ✅ |
| xharness | ✅ | ✅ | ✅ | — | — | — |
| Passwordless `sudo` for `log collect` | — | — | ✅ | — | ✅ | ✅ |
| ADB (`adb devices -l`) | ✅ | ✅ | — | — | — | — |

> **Apple platforms:** Startup measurement uses SpringBoard / system log timestamps. The `log collect` command requires `sudo`, and passwordless `sudo` is recommended to avoid interrupting automated measurement runs.

**Workloads installed by `prepare.sh`:**
- Android: `android`, `maui-android`
- iOS: `ios`, `maui-ios`
- macOS: `macos`
- Mac Catalyst: `maccatalyst`, `maui-maccatalyst`

## Quick Start

1. Clone the repo:

    ```bash
    git clone --recurse-submodules https://github.com/ivanpovazan/coreclr-android-perf.git
    cd ./coreclr-android-perf
    ```

2. Prepare the environment (pick your platform):

    ```bash
    # Android (default — physical device)
    ./prepare.sh

    # Apple platforms (physical devices)
    ./prepare.sh --platform ios
    ./prepare.sh --platform osx
    ./prepare.sh --platform maccatalyst

    # Emulator / Simulator
    ./prepare.sh --platform android-emulator
    ./prepare.sh --platform ios-simulator
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
| MONO_JIT | ✅ | ✅ | ❌ | ✅ |
| MONO_AOT | ✅ | ✅ | ❌ | ✅ |
| MONO_PAOT | ✅ | ✅ | ❌ | ✅ |
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
| `dotnet-new-maui` | `dotnet new maui` | ✅ | ✅ | ❌ | ✅ |
| `dotnet-new-maui-samplecontent` | `dotnet new maui --sample-content` | ✅ | ✅ | ❌ | ✅ |

> **Note:** Mac Catalyst has no standalone `dotnet new` template — only MAUI apps are available.
>
> **Note:** MAUI targets macOS through **Mac Catalyst** (`--platform maccatalyst`), not native macOS/AppKit (`--platform osx`). The `osx` platform only supports the standalone `dotnet-new-macos` app.

## SDK Version Pinning

The .NET SDK version is pinned in [`global.json`](./global.json). To test against a different SDK build:

1. Edit `global.json` and update the `version` field
2. Run `./prepare.sh -f` to reinstall

## Workload Version Pinning

Workload versions are implicitly pinned by the SDK version in [`global.json`](./global.json).
The `prepare.sh` script passes `--skip-manifest-update` to `dotnet workload install`, which
tells the SDK to use the workload manifests bundled in `sdk-manifests/` rather than downloading
new ones from NuGet. This ensures deterministic, reproducible workload installation without
maintaining a separate rollback file.

## Performance Measurements

### Measuring Startup

```bash
./measure_startup.sh <app> <build-config> [options]
```

**Options:**
- `--platform <android|android-emulator|ios|ios-simulator|osx|maccatalyst>` — Target platform (default: `android`)
- `--startup-iterations N` — Number of startup iterations (default: 10)
- `--disable-animations` — Disable device animations during measurement
- `--use-fully-drawn-time` — Use fully drawn time instead of displayed time
- `--fully-drawn-extra-delay N` — Extra delay for fully drawn time (seconds)
- `--trace-perfetto` — Capture a perfetto trace after measurements
- `--collect-trace` — Collect a .nettrace EventPipe trace (Apple platforms)
- `--pgo-mibc-dir <path>` — Directory containing `*.mibc` files for R2R_COMP_PGO builds

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

# Android emulator (see Emulator / Simulator Support section below)
./measure_startup.sh dotnet-new-android R2R --platform android-emulator

# iOS Simulator — routed transparently to ios/measure_simulator_startup.sh
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator --startup-iterations 10
```

### Measuring All Configurations

```bash
./measure_all.sh [options]
```

Runs `measure_startup.sh` for all (app, config) combinations and produces a summary table and CSV.

**Options:**
- `--platform <android|android-emulator|ios|ios-simulator|osx|maccatalyst>` — Target platform (default: `android`)
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

**Output:** `traces/<app>_<config>/<app>-<platform>-<config>-<YYYYMMDD-HHMMSS>.nettrace`

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
- Use `--platform android` for physical devices, `--platform android-emulator` for emulators (auto-selects correct RID)
- Apps: `dotnet-new-android`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*-Signed.apk` (single file)

### iOS

- Requires a physical iOS device connected via USB (`--platform ios`) or an iOS Simulator (`--platform ios-simulator`)
- Uses `xharness` for physical device deployment and app management
- Simulator uses `xcrun simctl` for deployment and wall-clock startup measurement (see [ios/README.md](./ios/README.md))
- 6 build configurations (no non-composite R2R)
- Apps: `dotnet-new-ios`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*.app` bundle (directory)

### macOS

- Runs locally on the Mac — no external device needed
- 3 build configurations (CoreCLR only)
- Apps: `dotnet-new-macos`
- Package format: `*.app` bundle (directory)

### Mac Catalyst

- MAUI-only — no standalone `dotnet new` template exists for Mac Catalyst
- Runs locally on the Mac — no external device needed
- 6 build configurations (no non-composite R2R)
- Apps: `dotnet-new-maui`, `dotnet-new-maui-samplecontent`
- Package format: `*.app` bundle (directory)

## Emulator / Simulator Support

In addition to physical devices, the tooling supports **Android emulators** and **iOS Simulators** via compound `--platform` values. These are useful for development iteration and relative performance comparison when a physical device is unavailable.

> **Important:** Emulator and simulator measurements are suitable for **relative comparison** between build configurations (e.g., comparing CORECLR_JIT vs R2R_COMP), but they do **not** reflect absolute device performance. Always use physical devices for final performance numbers.

### Supported Compound Platforms

| Platform value | Target | RID (Apple Silicon) | RID (Intel) |
|---|---|---|---|
| `android` | Physical Android device | `android-arm64` | `android-arm64` |
| `android-emulator` | Android emulator | `android-arm64` | `android-x64` |
| `ios` | Physical iOS device | `ios-arm64` | `ios-arm64` |
| `ios-simulator` | iOS Simulator | `iossimulator-arm64` | `iossimulator-x64` |

### RID Auto-Detection

When using `android-emulator` or `ios-simulator`, the Runtime Identifier (RID) is automatically selected based on your host machine architecture:

- **Apple Silicon** (M1/M2/M3/M4) → `arm64` variants (`android-arm64`, `iossimulator-arm64`)
- **Intel** → `x64` variants (`android-x64`, `iossimulator-x64`)

Physical device platforms (`android`, `ios`) always use `arm64` since modern devices are exclusively ARM.

### Workflow Examples

```bash
# Full workflow: prepare → build → measure on Android emulator
./prepare.sh --platform android-emulator
./build.sh --platform android-emulator dotnet-new-android CORECLR_JIT build 1
./measure_startup.sh dotnet-new-android CORECLR_JIT --platform android-emulator

# Full workflow: prepare → build → measure on iOS Simulator
./prepare.sh --platform ios-simulator
./build.sh --platform ios-simulator dotnet-new-ios CORECLR_JIT build 1
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator --startup-iterations 10

# Sweep all configs on emulator/simulator
./measure_all.sh --platform android-emulator --startup-iterations 5
./measure_all.sh --platform ios-simulator --startup-iterations 5
```

### How Measurement Works

- **Android emulator**: Uses the same `test.py` measurement harness as physical devices — ADB is transparent to the emulator/device distinction. The emulator must be visible via `adb devices -l`.
- **iOS Simulator**: Uses a custom measurement script (`ios/measure_simulator_startup.sh`) that measures wall-clock launch time via `xcrun simctl launch`. The `dotnet/performance` `test.py` harness only supports physical iOS devices (it hardcodes `--target ios-device` and `sudo log collect --device`), so the simulator path bypasses it entirely.
- **Nettrace collection**: iOS Simulator nettrace collection uses a direct Unix-domain diagnostic socket (no `dotnet-dsrouter` needed), following the same pattern as macOS/Mac Catalyst local tracing.

## Custom App Measurement

In addition to the generated sample apps, you can measure your own apps. There are two workflows: **source-based** custom apps (built from source by the repo tooling) and **pre-built** binaries (bring your own `.apk`, `.app`, or `.ipa`).

### Source-Based Custom Apps

Place your app source code in `custom-apps/<app-name>/` with a `.csproj` file whose name matches the directory:

```
custom-apps/
  hello-custom/
    hello-custom.csproj
    MainActivity.cs
```

An example `hello-custom` app is included in the repo as a reference.

**Registration:** Run `./prepare.sh` (with any `--platform` value) to copy custom apps into `apps/`. This happens automatically — custom apps are registered before any other setup steps, and re-registered on every `prepare.sh` run.

**Build and measure:**

```bash
# 1. Register the custom app (copies custom-apps/ → apps/)
./prepare.sh --platform android

# 2. Build the app
./build.sh --platform android hello-custom CORECLR_JIT build 1

# 3. Measure startup
./measure_startup.sh hello-custom CORECLR_JIT --platform android --startup-iterations 10
```

Custom apps automatically inherit build configurations from the repo's [`Directory.Build.props`](./Directory.Build.props) and [`Directory.Build.targets`](./Directory.Build.targets), so all build configs for the target platform work without any extra project-level configuration (7 on Android including standalone R2R; 6 on Apple platforms — see platform-specific `build-configs.props`).

### Pre-Built Binary Measurement

If you have an already-built package, you can skip the build step entirely and measure it directly using `--prebuilt --package-path`:

```bash
./measure_startup.sh <app-label> <config-label> --prebuilt --package-path <path> [options]
```

The `<app-label>` and `<config-label>` arguments are used for result naming only — they don't affect the measurement.

**Examples:**

```bash
# Android APK
./measure_startup.sh my-app CORECLR_JIT --prebuilt --package-path ./MyApp-Signed.apk --platform android

# iOS .app bundle (physical device)
./measure_startup.sh my-app R2R_COMP --prebuilt --package-path ./MyApp.app --platform ios

# macOS .app bundle
./measure_startup.sh my-app R2R_COMP --prebuilt --package-path ./MyApp.app --platform osx

# Mac Catalyst .app bundle
./measure_startup.sh my-app R2R_COMP --prebuilt --package-path ./MyApp.app --platform maccatalyst
```

**Bundle ID auto-detection:** The bundle identifier is automatically extracted from the package (via `Info.plist` for `.app`/`.ipa`, via `aapt2` for `.apk`). Use `--package-name <bundle-id>` to override auto-detection:

```bash
./measure_startup.sh my-app R2R_COMP --prebuilt --package-path ./MyApp.app --package-name com.example.myapp --platform ios
```

**iOS Simulator (pre-built):** Use the simulator startup script directly with `--package-path`:

```bash
./ios/measure_simulator_startup.sh my-app R2R_COMP --package-path ./MyApp.app --startup-iterations 10
```

### Conventions and Limitations

- **Directory naming:** The subdirectory name must match the `.csproj` file name (e.g., `my-app/my-app.csproj`).
- **Target frameworks:** Custom apps must target the correct TFM for the selected platform (`net11.0-android`, `net11.0-ios`, `net11.0-maccatalyst`, `net11.0-macos`). The TFM version should match the SDK version in `global.json`.
- **Reserved name prefixes:** App names that produce assembly names starting with `Microsoft.`, `System.`, `Mono.`, or `Xamarin.` should be avoided — these collide with framework assembly filters used in R2R compilation and may cause unexpected build behavior.
- **NuGet dependencies:** If your app has external NuGet package dependencies, add the required feeds to [`NuGet.config`](./NuGet.config).
- **MAUI apps:** MAUI-based custom apps work on Android, iOS, and Mac Catalyst, but **not** on macOS/AppKit (`--platform osx`). The `osx` platform only supports AppKit apps (the `dotnet new macos` template).
- **Tracking:** `custom-apps/` is git-tracked — commit your custom app source code here. `apps/` is gitignored and populated at prepare time.

## Cleaning Builds

```bash
./clean.sh <all|APP_NAME>
```

Cleans build artifacts (`bin/`, `obj/`, binlogs) for the specified app or all apps.

## Project Structure

```
├── global.json               # SDK version pinning
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
├── download-mibc.sh           # Download PGO .mibc profiles for R2R_COMP_PGO builds
├── docs/                      # Additional documentation
│   └── BUILD-CONFIGS.md       #   Detailed build configuration reference
├── android/                   # Android-specific files
│   ├── build-configs.props    #   Build configs (7 configs incl. R2R)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (via dsrouter + ADB)
│   ├── print_apk_sizes.sh    #   APK size reporting
│   ├── env.txt                #   DiagnosticPorts config for profiling
│   └── env-nettrace.txt       #   PGO instrumentation env vars
├── ios/                       # iOS-specific files
│   ├── README.md              #   iOS platform documentation
│   ├── build-configs.props    #   Build configs (6 configs, composite R2R only)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (device via dsrouter + USB, simulator via direct socket)
│   ├── measure_device_startup.sh  #   Physical device startup measurement
│   ├── measure_simulator_startup.sh  #   Simulator startup measurement (wall-clock)
│   └── print_app_sizes.sh    #   .app bundle size reporting
├── osx/                       # macOS-specific files
│   ├── README.md              #   macOS platform documentation
│   ├── build-configs.props    #   Build configs (3 configs, CoreCLR only)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (local, no dsrouter)
│   ├── measure_osx_startup.sh #   macOS startup measurement
│   └── print_app_sizes.sh    #   .app bundle size reporting
├── maccatalyst/               # Mac Catalyst-specific files
│   ├── README.md              #   Mac Catalyst platform documentation
│   ├── build-configs.props    #   Build configs (6 configs, composite R2R only)
│   ├── build-workarounds.targets  #   Build workarounds
│   ├── collect_nettrace.sh    #   .nettrace trace collection (local, no dsrouter)
│   ├── measure_maccatalyst_startup.sh  #   Mac Catalyst startup measurement
│   └── print_app_sizes.sh    #   .app bundle size reporting
├── custom-apps/               # User-provided custom apps (git-tracked)
│   └── hello-custom/          #   Example custom Android app
├── external/performance/      # dotnet/performance submodule
├── apps/                      # Generated + custom apps (gitignored, populated by prepare.sh)
├── .dotnet/                   # Local .NET SDK install (gitignored)
├── build/                     # Build artifacts (gitignored)
├── nettrace-analysis/         # Nettrace analysis output (gitignored)
├── profiles/                  # Shared PGO .mibc profiles (gitignored)
├── traces/                    # Collected .nettrace traces (gitignored)
├── results/                   # Measurement results (gitignored)
├── versions.log               # SDK/workload version log (gitignored)
└── tools/                     # Tools (dotnet-install.sh, xharness) (gitignored)
```
