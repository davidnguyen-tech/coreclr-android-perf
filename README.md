# .NET Android Performance Measurements

Repository for measuring startup performance, build times, and APK sizes of .NET Android apps using the [dotnet/performance](https://github.com/dotnet/performance) tooling.

## Prerequisites

- **Android device** (developer mode enabled) or emulator, visible via `adb devices -l`
- **Python 3** (any supported 3.x version)
- **curl** (for downloading dotnet-install script and NuGet.config)
- **git** (for submodule initialization)

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
    ./measure_startup.sh dotnet-new-android coreclr R2R
    ```

4. Inspect results in the console output.

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
./measure_startup.sh <app> <runtime> <build-config> [options]
```

**Apps:** `dotnet-new-android`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`

**Runtimes:** `mono`, `coreclr`

**Build configs:** `JIT`, `AOT`, `PAOT`, `R2R`, `R2R_COMP`, `R2R_COMP_PGO`

**Options:**
- `--disable-animations` — Disable device animations during measurement
- `--use-fully-drawn-time` — Use fully drawn time instead of displayed time
- `--fully-drawn-extra-delay N` — Extra delay for fully drawn time (seconds)
- `--trace-perfetto` — Capture a perfetto trace after measurements

**Examples:**

```bash
# CoreCLR R2R startup of dotnet new android
./measure_startup.sh dotnet-new-android coreclr R2R

# Mono JIT startup of MAUI app with animations disabled
./measure_startup.sh dotnet-new-maui mono JIT --disable-animations

# CoreCLR R2R Composite with PGO
./measure_startup.sh dotnet-new-maui-samplecontent coreclr R2R_COMP_PGO
```

### Building / Running Sample Apps Manually

```bash
./build.sh <app> <mono|coreclr> <build|run> <ntimes> [additional_args]
```

**Examples:**

```bash
# Build dotnet new android with Mono JIT
./build.sh dotnet-new-android mono build 1 -p:_BuildConfig=JIT

# Run dotnet new maui with CoreCLR R2R + marshal methods
./build.sh dotnet-new-maui coreclr run 1 "-p:_BuildConfig=R2R -p:AndroidEnableMarshalMethods=true"
```

Build artifacts are copied to `./build/` for further inspection (APKs, binlogs).

### Measuring APK Sizes

```bash
./print_apk_sizes.sh [-unzipped]
```

Scans the `./build/` directory for signed APKs and prints their sizes. Pass `-unzipped` to unpack and show extracted sizes.

## Runtime Configurations

| Config | Runtime | Description |
|--------|---------|-------------|
| JIT | Mono | Mono with JIT enabled |
| AOT | Mono | Mono with full AOT |
| PAOT | Mono | Mono with profile-guided AOT |
| JIT | CoreCLR | CoreCLR with JIT only |
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
├── Directory.Build.props     # Build configuration presets
├── Directory.Build.targets   # Build targets (R2R workarounds)
├── prepare.sh                # Environment setup (SDK, workloads, xharness, apps)
├── generate-apps.sh          # Dynamic sample app generation
├── build.sh                  # Build/run sample apps
├── measure_startup.sh        # Startup measurement using dotnet/performance
├── clean.sh                  # Clean build artifacts
├── print_apk_sizes.sh        # APK size reporting
├── dotnet-local.sh           # Proxy to local .NET SDK
├── env.txt                   # DiagnosticPorts config for profiling
├── profiles/                 # Shared PGO .mibc profiles
├── external/performance/     # dotnet/performance submodule
├── apps/                     # Generated sample apps (gitignored)
├── .dotnet/                  # Local .NET SDK install (gitignored)
├── build/                    # Build artifacts (gitignored)
└── tools/                    # Tools (dotnet-install.sh, xharness) (gitignored)
```
