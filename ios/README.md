# iOS Performance Measurement Support

iOS-specific build configurations, workarounds, and tooling for CoreCLR startup performance measurement on physical iOS devices and the iOS Simulator.

## Prerequisites

- **macOS** with Xcode installed (latest stable recommended)
- **Physical iPhone** (arm64) for device measurements (`--platform ios`)
- **iOS Simulator** for simulator measurements (`--platform ios-simulator`) — no physical device or code signing required
- **Apple Developer account** with a valid provisioning profile for physical device deployment
- **Xcode 15+** for `xcrun devicectl` (device interaction and app management)

## Build Configurations

iOS uses 6 build configurations. Non-composite ReadyToRun (`R2R`) is **not available** on Apple platforms because the MachO binary format only supports Composite R2R images.

| Config | Runtime | UseMonoRuntime | AOT | Profiled AOT | R2R | R2R Composite | PGO |
|--------|---------|---------------|-----|-------------|-----|---------------|-----|
| `MONO_JIT` | Mono | True | No | — | No | No | — |
| `MONO_AOT` | Mono | True | Yes | No | — | — | — |
| `MONO_PAOT` | Mono | True | Yes | Yes (default) | — | — | — |
| `CORECLR_JIT` | CoreCLR | False | No | — | No | No | — |
| `R2R_COMP` | CoreCLR | False | — | — | Yes | Yes | — |
| `R2R_COMP_PGO` | CoreCLR | False | — | — | Yes | Yes | Yes |

### Configuration Details

- **MONO_JIT** — Mono runtime with JIT compilation only. Baseline for Mono performance.
- **MONO_AOT** — Mono runtime with full Ahead-of-Time compilation (`RunAOTCompilation=True`, `MtouchProfiledAOT=False`).
- **MONO_PAOT** — Mono runtime with profiled AOT (`RunAOTCompilation=True`, `MtouchProfiledAOT=True`). This is the default AOT mode that uses profiling data to prioritize which methods to AOT compile.
- **CORECLR_JIT** — CoreCLR runtime with JIT compilation only. Baseline for CoreCLR performance.
- **R2R_COMP** — CoreCLR with Composite ReadyToRun images (`PublishReadyToRun=True`, `PublishReadyToRunComposite=True`). Pre-compiled native code for faster startup.
- **R2R_COMP_PGO** — Composite ReadyToRun with PGO (Profile-Guided Optimization) profiles from `dotnet-optimization` CI for optimized native code layout.

### Why No Non-Composite R2R?

Apple platforms use the **MachO** binary format, which only supports Composite ReadyToRun images. The crossgen2 compiler cannot produce non-composite R2R images for MachO targets. This is a platform limitation — Android (ELF format) supports both composite and non-composite R2R.

## iOS-Specific MSBuild Properties

| Property | Description |
|----------|-------------|
| `MtouchProfiledAOT` | iOS equivalent of Android's `AndroidEnableProfiledAot`. Controls whether profiled AOT compilation is used. |
| `UseMonoRuntime` | Selects Mono (`True`) or CoreCLR (`False`) runtime. Same as Android. |
| `RunAOTCompilation` | Enables AOT compilation. Same as Android. |
| `PublishReadyToRun` | Enables ReadyToRun compilation. Same as Android. |
| `PublishReadyToRunComposite` | Enables composite R2R. Must be `True` for iOS (non-composite not supported). |

## Usage

### Setup

```bash
# Install SDK, workloads, and tools for iOS
./prepare.sh --platform ios

# Generate sample iOS apps
./generate-apps.sh --platform ios
```

### Building

```bash
# Build a specific app with a specific config
./build.sh --platform ios dotnet-new-ios CORECLR_JIT build 1

# Build MAUI app with R2R Composite
./build.sh --platform ios dotnet-new-maui R2R_COMP build 1
```

### Measuring Startup

```bash
# Measure a single app/config combination
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios

# Measure all iOS apps across all configs
./measure_all.sh --platform ios

# Measure with fewer iterations for quick testing
./measure_all.sh --platform ios --startup-iterations 3
```

### App Size Reporting

```bash
# Print sizes of built iOS .app bundles
./ios/print_app_sizes.sh

# Detailed view showing largest files in each bundle
./ios/print_app_sizes.sh -detailed
```

## Package Discovery

iOS apps are built as `.app` directory bundles (not single files like Android APKs). The measurement scripts use:

- `find` with `*.app` glob to locate built bundles
- `du -sk` to measure total bundle size (since `stat` on a directory doesn't give content size)
- Bundles are found under `apps/<app-name>/bin/Release/net11.0-ios/ios-arm64/`

## Device Deployment

iOS physical device startup measurement uses the dedicated `ios/measure_device_startup.sh` script:

- **`xcrun devicectl`** for app installation, launching, and termination
- **`sudo log collect --device`** for post-hoc device log collection
- **SpringBoard Watchdog event parsing** for precise time-to-main and time-to-first-draw
- **Code signing** is required — the app must be signed with a valid development certificate and provisioning profile

> **Note:** This approach is adapted from dotnet/performance's `runner.py`, which uses the same `sudo log collect --device` + SpringBoard Watchdog parsing technique. It requires passwordless sudo configured for `log collect`.

## Simulator Support

The iOS Simulator is supported as an alternative to physical devices for development iteration and relative performance comparison. Use `--platform ios-simulator` throughout the workflow.

> **Note:** Simulator startup times are **not** comparable to physical device times. Use simulator measurements for relative comparison between build configurations only.

### Quick Start (Simulator)

```bash
# Prepare (installs SDK, workloads, generates apps)
./prepare.sh --platform ios-simulator

# Build
./build.sh --platform ios-simulator dotnet-new-ios CORECLR_JIT build 1

# Measure startup (transparently routes to ios/measure_simulator_startup.sh)
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator

# Or call the dedicated script directly for simulator-specific options
./ios/measure_simulator_startup.sh dotnet-new-ios CORECLR_JIT --simulator-name 'iPhone 16 Pro'

# Sweep all configs
./measure_all.sh --platform ios-simulator --startup-iterations 5
```

### How It Works

- **RID**: `iossimulator-arm64` on Apple Silicon (M1/M2/M3/M4), `iossimulator-x64` on Intel Macs. The RID is auto-detected based on host architecture.
- **Measurement**: The custom `ios/measure_simulator_startup.sh` script measures wall-clock duration of `xcrun simctl launch`, which returns after the app process has started. This is a proxy for process startup time — it does not measure time-to-interactive.
- **No code signing**: Simulator builds do not require an Apple Developer account or provisioning profiles.
- **No xharness**: Simulator deployment uses `xcrun simctl install` / `xcrun simctl launch` directly — xharness is not needed.
- **No `sudo`**: Simulator measurements do not use `log collect` and do not require sudo access.

### Simulator Auto-Detection

When no simulator is specified, the script automatically:

1. Checks for a **currently booted** simulator and uses it if found.
2. If none is booted, finds an **available iPhone simulator** (preferring newer runtimes).
3. **Boots the simulator** automatically if it was not already running.

You can also specify a simulator explicitly:

```bash
# By name (use a simulator available on your machine; run `xcrun simctl list devices` to see options)
./ios/measure_simulator_startup.sh dotnet-new-ios CORECLR_JIT --simulator-name 'iPhone 16 Pro'

# By UDID
./ios/measure_simulator_startup.sh dotnet-new-ios CORECLR_JIT --simulator-udid <UDID>
```

> **Tip:** By default, the script auto-detects a booted simulator (or picks one and boots it). Use `--simulator-name` only when you need to target a specific device model.

### Simulator `measure_simulator_startup.sh` Options

```
Usage: ios/measure_simulator_startup.sh <app-name> <build-config> [options]

Options:
  --startup-iterations N   Number of startup iterations (default: 10)
  --simulator-name NAME    Simulator name (e.g. 'iPhone 16')
  --simulator-udid UDID    Simulator UDID (overrides --simulator-name)
  --no-build               Skip building, use existing .app bundle
```

### Simulator Nettrace Collection

For `.nettrace` trace collection on the simulator, use:

```bash
./ios/collect_nettrace.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator
```

The simulator runs locally, so nettrace collection uses a **direct Unix-domain diagnostic socket** — no `dotnet-dsrouter` bridge is needed. This follows the same pattern as macOS and Mac Catalyst local tracing.

## Device Measurement

Physical iOS device measurement uses `ios/measure_device_startup.sh` for direct device interaction via `xcrun devicectl`, bypassing `test.py`.

### Prerequisites

- Physical iPhone/iPad connected via **USB** (WiFi may work but is less reliable for log collection)
- Device must be **unlocked and trusted**
- **Developer Mode** enabled (Settings > Privacy & Security > Developer Mode)
- Valid **code signing identity** (Xcode-managed automatic signing is recommended)
- **Xcode 15+** (required for `xcrun devicectl`)
- **Passwordless sudo** configured for `log collect` (device log collection)

> **Passwordless sudo setup:** Add to `/etc/sudoers` via `visudo`:
> ```
> <username> ALL=(ALL) NOPASSWD: /usr/bin/log
> ```

### Quick Start (Device)

```bash
# Prepare (installs SDK, workloads, generates apps)
./prepare.sh --platform ios

# Build
./build.sh --platform ios dotnet-new-ios CORECLR_JIT build 1

# Measure startup
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios

# Or call the dedicated script directly
./ios/measure_device_startup.sh dotnet-new-ios CORECLR_JIT

# Sweep all configs
./measure_all.sh --platform ios --startup-iterations 10
```

### How It Works

- **RID**: `ios-arm64` — physical iOS devices are always arm64
- **Measurement**: `ios/measure_device_startup.sh` collects device logs post-hoc via `sudo log collect --device` after each app launch, then parses SpringBoard Watchdog events to extract precise time-to-main and time-to-first-draw. This is the same technique used by dotnet/performance's `runner.py` in CI.
- **Code signing**: Required — Apple Developer account with provisioning profile. The script does not manage signing — it relies on the developer's Xcode signing configuration.
- **Warmup iteration**: Iteration 0 is a warmup used to establish a device-side time reference, avoiding host-device clock drift. Measured iterations start from 1.

### Device Auto-Detection

When no device is specified, the script automatically:

1. Queries `xcrun devicectl list devices` for connected iOS devices.
2. Selects the first available device.
3. Displays device name and iOS version for confirmation.

You can also specify a device explicitly:

```bash
# By UDID (run `xcrun devicectl list devices` to find your device's UDID)
./ios/measure_device_startup.sh dotnet-new-ios CORECLR_JIT --device-udid XXXXXXXX-XXXXXXXXXXXX
```

> **Tip:** By default, the script auto-detects a connected device. Use `--device-udid` only when multiple devices are connected and you need to target a specific one.

### Device `measure_device_startup.sh` Options

```
Usage: ios/measure_device_startup.sh <app-name> <build-config> [options]

Options:
  --startup-iterations N   Number of startup iterations (default: 10)
  --device-udid UDID       Target a specific device (auto-detect if omitted)
  --no-build               Skip building, use existing .app bundle
  --package-path PATH      Path to pre-built .app bundle (implies --no-build)
  --collect-trace          Collect .nettrace trace (not yet supported for device)
```

## File Structure

```
ios/
├── README.md                       # This file
├── build-configs.props             # 6 build configuration presets
├── build-workarounds.targets       # iOS-specific build targets
├── collect_nettrace.sh             # .nettrace trace collection (device via dsrouter, simulator via direct socket)
├── measure_device_startup.sh       # Physical device startup measurement (SpringBoard Watchdog timing)
├── measure_simulator_startup.sh    # Simulator startup measurement (host log stream timing)
└── print_app_sizes.sh              # .app bundle size reporting
```
