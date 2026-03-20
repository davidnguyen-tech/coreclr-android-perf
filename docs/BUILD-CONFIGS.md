# Build Configuration Reference

This document describes all build configurations used across platforms in this
performance measurement repo, the MSBuild properties each sets, and the audit
findings that led to critical fixes.

Each platform defines its configurations in `<platform>/build-configs.props`.
The build system selects a configuration by setting the `_BuildConfig` MSBuild
property.

---

## Configuration Reference Tables

### Android (`android/build-configs.props`)

7 configurations — all runtimes and R2R modes are available.

| Config | Runtime | AOT Mode | R2R Mode | Key MSBuild Properties |
|--------|---------|----------|----------|----------------------|
| `MONO_JIT` | Mono | None | None | `UseMonoRuntime=True` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `MONO_AOT` | Mono | Full AOT | None | `UseMonoRuntime=True` `RunAOTCompilation=True` `AndroidEnableProfiledAot=False` |
| `MONO_PAOT` | Mono | Profiled AOT | None | `UseMonoRuntime=True` `RunAOTCompilation=True` (profiled AOT is the default) |
| `CORECLR_JIT` | CoreCLR | None | None | `UseMonoRuntime=False` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `R2R` | CoreCLR | None | Non-composite | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=False` |
| `R2R_COMP` | CoreCLR | None | Full Composite | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `_MauiPublishReadyToRunPartial=false` |
| `R2R_COMP_PGO` | CoreCLR | None | Partial Composite + PGO | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `PGO=True` `PublishReadyToRunCrossgen2ExtraArgs=--partial` |

### iOS (`ios/build-configs.props`)

6 configurations — no non-composite R2R (MachO limitation).

| Config | Runtime | AOT Mode | R2R Mode | Key MSBuild Properties |
|--------|---------|----------|----------|----------------------|
| `MONO_JIT` | Mono | None | None | `UseMonoRuntime=True` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `MONO_AOT` | Mono | Full AOT | None | `UseMonoRuntime=True` `RunAOTCompilation=True` `MtouchProfiledAOT=False` |
| `MONO_PAOT` | Mono | Profiled AOT | None | `UseMonoRuntime=True` `RunAOTCompilation=True` (profiled AOT is the default) |
| `CORECLR_JIT` | CoreCLR | None | None | `UseMonoRuntime=False` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `R2R_COMP` | CoreCLR | None | Full Composite | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `_MauiPublishReadyToRunPartial=false` |
| `R2R_COMP_PGO` | CoreCLR | None | Partial Composite + PGO | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `PGO=True` `PublishReadyToRunCrossgen2ExtraArgs=--partial` |

### Mac Catalyst (`maccatalyst/build-configs.props`)

6 configurations — same as iOS (MachO limitation applies).

| Config | Runtime | AOT Mode | R2R Mode | Key MSBuild Properties |
|--------|---------|----------|----------|----------------------|
| `MONO_JIT` | Mono | None | None | `UseMonoRuntime=True` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `MONO_AOT` | Mono | Full AOT | None | `UseMonoRuntime=True` `RunAOTCompilation=True` `MtouchProfiledAOT=False` |
| `MONO_PAOT` | Mono | Profiled AOT | None | `UseMonoRuntime=True` `RunAOTCompilation=True` (profiled AOT is the default) |
| `CORECLR_JIT` | CoreCLR | None | None | `UseMonoRuntime=False` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `R2R_COMP` | CoreCLR | None | Full Composite | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `_MauiPublishReadyToRunPartial=false` |
| `R2R_COMP_PGO` | CoreCLR | None | Partial Composite + PGO | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `PGO=True` `PublishReadyToRunCrossgen2ExtraArgs=--partial` |

### macOS (`osx/build-configs.props`)

3 configurations — CoreCLR only (Mono is not supported on this platform).

| Config | Runtime | AOT Mode | R2R Mode | Key MSBuild Properties |
|--------|---------|----------|----------|----------------------|
| `CORECLR_JIT` | CoreCLR | None | None | `UseMonoRuntime=False` `RunAOTCompilation=False` `PublishReadyToRun=False` |
| `R2R_COMP` | CoreCLR | None | Full Composite | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `PublishReadyToRunContainerFormat=macho` `_MauiPublishReadyToRunPartial=false` |
| `R2R_COMP_PGO` | CoreCLR | None | Partial Composite + PGO | `UseMonoRuntime=False` `PublishReadyToRun=True` `PublishReadyToRunComposite=True` `PublishReadyToRunContainerFormat=macho` `PGO=True` `PublishReadyToRunCrossgen2ExtraArgs=--partial` |

---

## Configuration Details

### MONO_JIT

Mono runtime with JIT compilation only. No ahead-of-time compilation is
performed — all methods are JIT-compiled at runtime. This is the baseline Mono
configuration and the fastest to build, but has the slowest startup because
every method must be compiled on first use.

**When to use:** Baseline measurement for Mono; fast iteration during
development.

### MONO_AOT

Mono runtime with full AOT. Every method is compiled ahead of time. This
produces the fastest Mono startup but the longest build times and largest
package sizes.

On Android, full AOT is controlled by `RunAOTCompilation=True` with
`AndroidEnableProfiledAot=False`. On iOS/Mac Catalyst, `MtouchProfiledAOT=False`
is used instead.

**When to use:** Measuring best-case Mono startup performance.

### MONO_PAOT

Mono runtime with profiled AOT. Only "hot" methods (identified by a profile)
are compiled ahead of time. Methods not in the profile are JIT-compiled at
runtime. This balances startup speed against package size.

On Android, profiled AOT is the default when `RunAOTCompilation=True` and
`AndroidEnableProfiledAot` is not explicitly set to `False`. On iOS/Mac Catalyst,
profiled AOT is the default when `MtouchProfiledAOT` is not set to `False`.

**When to use:** Measuring the default Mono release experience for production
apps.

### CORECLR_JIT

CoreCLR runtime with JIT compilation only. No ReadyToRun precompilation. This
is the CoreCLR baseline — all methods are JIT-compiled at runtime.

**When to use:** Baseline measurement for CoreCLR; isolating JIT vs R2R
performance differences.

### R2R (Android only)

CoreCLR with non-composite ReadyToRun. Each assembly is R2R-compiled
separately into its own native code image. The JIT still handles cross-assembly
calls and methods that weren't precompiled.

This configuration is only available on Android. iOS, Mac Catalyst, and macOS
use the MachO binary format which only supports composite R2R images.

**When to use:** Measuring per-assembly R2R without composite overhead;
comparing against composite R2R to quantify cross-assembly optimization
benefits.

### R2R_COMP

CoreCLR with full composite ReadyToRun. All assemblies are compiled together
into a single R2R image by crossgen2 with `--composite`. This enables
cross-assembly inlining and optimization, producing the best R2R startup
performance.

The `_MauiPublishReadyToRunPartial=false` property ensures the MAUI SDK does
not inject `--partial` into the crossgen2 arguments, keeping this a true full
composite build.

**When to use:** Measuring best-case CoreCLR startup with full R2R coverage.

### R2R_COMP_PGO

CoreCLR with partial composite ReadyToRun guided by PGO profiles. Only methods
that have profile data (from `.mibc` files) are R2R-compiled; the rest are left
for JIT. The crossgen2 `--partial` flag enables this selective compilation.

The `PGO=True` property causes the build system to feed `.mibc` profile files
to crossgen2. The `PublishReadyToRunCrossgen2ExtraArgs=--partial` property adds
the `--partial` flag to the crossgen2 invocation.

**When to use:** Measuring production-like scenarios where PGO profiles guide
R2R compilation for optimal startup with smaller package size than full
composite.

---

## Audit Findings

A comprehensive binlog audit of all build configurations uncovered several bugs.
Full details are in `BINLOG_AUDIT_RESULTS.md` and
`BINLOG_AUDIT_EXECUTIVE_SUMMARY.txt`.

### 1. CRITICAL: R2R_COMP_PGO was producing Full Composite for MAUI apps

**Severity:** Critical — completely defeated the purpose of the PGO configuration.

**Symptom:** Binlog analysis showed that `--partial` was present in crossgen2
arguments for non-MAUI Android apps but absent for MAUI apps (maui,
maui-samplecontent). All 3 audited MAUI R2R_COMP_PGO builds were producing
full composite images instead of partial composite.

**Root cause:** The `_MauiPublishReadyToRunPartial=false` property was set in
the R2R_COMP_PGO PropertyGroup. This internal MAUI SDK property controls whether
`--partial` is appended to crossgen2 arguments. Setting it to `false` caused the
MAUI SDK to strip `--partial` from the crossgen2 command line, overriding the
`PublishReadyToRunCrossgen2ExtraArgs=--partial` that was also set.

Non-MAUI apps (plain `dotnet-new-android`) were unaffected because they don't
use the MAUI SDK targets that read `_MauiPublishReadyToRunPartial`.

**Fix:** Removed `_MauiPublishReadyToRunPartial=false` from R2R_COMP_PGO
PropertyGroups across all platform build-configs.props files.

### 2. measure_all.sh silently dropped --collect-trace for Android

**Symptom:** Running `./measure_all.sh --collect-trace` would collect nettrace
files for Apple platforms but silently skip trace collection for Android.

**Root cause:** The `$COLLECT_TRACE_FLAG` variable was not included in the
Android dispatch branch of `measure_all.sh`.

**Fix:** Added `$COLLECT_TRACE_FLAG` to the Android `measure_startup.sh`
invocation in `measure_all.sh`.

### 3. Hardcoded diagnostic tool DLL paths in android/collect_nettrace.sh

**Symptom:** The script used hardcoded paths to `dotnet-dsrouter` and
`dotnet-trace` DLLs, which would break if tool versions changed.

**Fix:** Replaced hardcoded paths with a dynamic `resolve_tool_dll` function
that discovers the DLL location at runtime.

### 4. Apple nettrace scripts vulnerable to macOS amfid SIGKILL

**Symptom:** On macOS, the `amfid` code-signing daemon could kill unsigned
.NET tool executables, causing nettrace collection to fail silently.

**Fix:** Applied the same `resolve_tool_dll` pattern (invoking tools via
`dotnet exec <tool>.dll` instead of the native executable) to the
`ios/collect_nettrace.sh`, `osx/collect_nettrace.sh`, and
`maccatalyst/collect_nettrace.sh` scripts.

---

## Verification

The automated verification script `tools/verify-build-config.sh` validates that
MSBuild properties resolve to expected values for every (platform, config)
combination — without performing a full build.

```bash
# Verify all platforms
./tools/verify-build-config.sh

# Verify a specific platform
./tools/verify-build-config.sh --platform android
./tools/verify-build-config.sh --platform ios
./tools/verify-build-config.sh --platform osx
./tools/verify-build-config.sh --platform maccatalyst
```

The script checks key properties like `PublishReadyToRun`,
`PublishReadyToRunComposite`, and `PublishReadyToRunCrossgen2ExtraArgs` against
expected values. It exits with code 0 when all checks pass and code 1 on any
failure.

**Prerequisites:** Run `./prepare.sh` first to generate the app projects in
`apps/`.

---

## Platform Limitations

- **iOS / Mac Catalyst (MachO format):** Only composite R2R is supported.
  Non-composite R2R (`R2R`) is unavailable because the MachO binary format
  does not support per-assembly R2R images.

- **macOS:** Only the CoreCLR runtime is supported. Mono configurations
  (`MONO_JIT`, `MONO_AOT`, `MONO_PAOT`) are unavailable.

- **macOS R2R container format:** The `PublishReadyToRunContainerFormat=macho`
  property is explicitly set in macOS R2R configs (`osx/build-configs.props`).
  iOS and Mac Catalyst auto-detect this from their respective SDKs.

- **R2R requires `_IsPublishing=True`:** All R2R configurations set
  `_IsPublishing=True` to enable the crossgen2 build targets, which normally
  only run during `dotnet publish`.

- **`_MauiPublishReadyToRunPartial=false`:** Set in `R2R` and `R2R_COMP`
  configs to prevent the MAUI SDK from injecting `--partial` into crossgen2
  arguments. This property must **not** be set in `R2R_COMP_PGO` (see Audit
  Finding #1 above).
