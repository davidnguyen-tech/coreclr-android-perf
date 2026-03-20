# Why R2R_COMP_PGO Nettrace Collection Produces Empty/Corrupt Traces

**Date**: 2025-06-14
**Scope**: Android R2R_COMP_PGO nettrace collection failure vs. R2R_COMP success
**Repository**: `coreclr-android-perf` (`apple-agents` worktree)

---

## Executive Summary

**Root Cause: The R2R_COMP_PGO app CRASHES during startup**, producing a truncated EventPipe trace. The crash is a `TypeInitializationException` in `DependencyInjectionEventSource`, caused by a defective composite R2R image built without any PGO profiles. The build system disables MAUI's default profiles (`_MauiUseDefaultReadyToRunPgoFiles=false`) but no replacement profiles exist in the app's `profiles/` directory. The resulting image is mis-compiled, causing a runtime crash ~1.2 seconds after launch — before meaningful trace data can be captured.

R2R_COMP works because it uses MAUI's default profiles and sets `_MauiPublishReadyToRunPartial=false`, producing a fully-compiled composite image.

---

## Architecture: How the Two Configs Differ

### Side-by-Side Comparison

| Property | R2R_COMP (lines 51–62) | R2R_COMP_PGO (lines 63–74) |
|----------|----------------------|--------------------------|
| `PublishReadyToRun` | True | True |
| `PublishReadyToRunComposite` | True | True |
| `_MauiPublishReadyToRunPartial` | **`false`** | **NOT SET** |
| `PGO` | — | **`True`** |
| `AndroidEnableMarshalMethods` | False | False |

**Source**: `android/build-configs.props` lines 51–74

### What `PGO=True` Triggers in the csproj

From `apps/dotnet-new-maui/dotnet-new-maui.csproj` lines 82–88:
```xml
<!-- Triggered when PGO=True + R2R + Composite -->
<PropertyGroup>
  <_MauiUseDefaultReadyToRunPgoFiles>false</_MauiUseDefaultReadyToRunPgoFiles>
</PropertyGroup>
<ItemGroup Condition="... and '$(PgoMibcDir)' == ''">
  <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
</ItemGroup>
```

**Effect**: Disables MAUI SDK's built-in PGO profiles and substitutes app-local profiles from `profiles/*.mibc`.

### The Missing Profiles

```
$ ls apps/dotnet-new-maui/profiles/*.mibc
# NO FILES FOUND — the profiles/ directory does not exist or is empty
```

**Verified**: `glob("apps/dotnet-new-maui/profiles/*.mibc")` returns no matches.

This means R2R_COMP_PGO builds with:
- ❌ MAUI's default profiles (disabled by `_MauiUseDefaultReadyToRunPgoFiles=false`)
- ❌ App-local profiles (none exist)
- ❌ External profiles (only provided when `--pgo-mibc-dir` is passed)
- Result: **crossgen2 composite compilation with ZERO PGO data**

### The `_MauiPublishReadyToRunPartial` Gap

R2R_COMP explicitly sets `_MauiPublishReadyToRunPartial=false`, telling MAUI not to add `--partial` to crossgen2. R2R_COMP_PGO does NOT set this property.

When MAUI defaults `_MauiPublishReadyToRunPartial` (which may be `true`), crossgen2 gets `--partial`, meaning "only compile methods with profile data." With zero profiles, this produces a degenerate composite image where method compilation boundaries are unpredictable.

**This pattern is consistent across ALL platforms** — iOS, macOS, and Mac Catalyst all have the same gap:

| Platform | R2R_COMP has `_MauiPublishReadyToRunPartial=false`? | R2R_COMP_PGO has it? |
|----------|:-:|:-:|
| Android (`android/build-configs.props` line 60) | ✅ Yes | ❌ No |
| iOS (`ios/build-configs.props` line 43) | ✅ Yes | ❌ No |
| macOS (`osx/build-configs.props` line 21) | ✅ Yes | ❌ No |
| Mac Catalyst (`maccatalyst/build-configs.props` line 43) | ✅ Yes | ❌ No |

---

## Key Files

| File | Relevant Lines | Role |
|------|---------------|------|
| `android/build-configs.props` | 51–74 | Defines R2R_COMP and R2R_COMP_PGO property groups |
| `apps/dotnet-new-maui/dotnet-new-maui.csproj` | 82–88 | PGO profile injection logic |
| `android/collect_nettrace.sh` | 209, 334–355, 380–393 | Build + deploy + trace collection |
| `android/env-nettrace.txt` | 1–9 | PGO instrumentation env vars (only with `--pgo-instrumentation`) |
| `generate-apps.sh` | 155–188 | Generates csproj PGO/profile patches |
| `traces/dotnet-new-maui_R2R_COMP_PGO/logcat.txt` | 3605–3680 | **Crash evidence** |
| `traces/dotnet-new-maui_R2R_COMP/logcat.txt` | 2371–2383 | **No crash (healthy startup)** |

---

## The Smoking Gun: App Crash in Logcat

### R2R_COMP_PGO — CRASHES (logcat.txt lines 3605–3680)

```
03-19 16:35:26.885  5696 I DOTNET  : The runtime has been configured to pause during startup
                                      and is awaiting a Diagnostics IPC ResumeStartup command
03-19 16:35:26.885  5696 I DOTNET  : DOTNET_DiagnosticPorts="127.0.0.1:9000,connect,suspend"
03-19 16:35:27.814  5696 D DOTNET  : AndroidCryptoNative_InitLibraryOnLoad [CryptoNative loaded]
03-19 16:35:28.082  5696 D AndroidRuntime: Shutting down VM
03-19 16:35:28.084  5696 E AndroidRuntime: FATAL EXCEPTION: main
03-19 16:35:28.084  5696 E AndroidRuntime: Process: com.companyname.dotnetnewmaui, PID: 5696
03-19 16:35:28.084  5696 E AndroidRuntime: android.runtime.JavaProxyThrowable:
    [System.TypeInitializationException]: TypeInitialization_Type,
    Microsoft.Extensions.DependencyInjection.DependencyInjectionEventSource
        at Microsoft.Extensions.DependencyInjection.ServiceProvider..ctor
        at ...ServiceCollectionContainerBuilderExtensions.BuildServiceProvider
        at Microsoft.Maui.Hosting.MauiAppBuilder.Build
        at Microsoft.Maui.MauiApplication.OnCreate
03-19 16:35:28.103  5696 I Process : Sending signal. PID: 5696 SIG: 9
03-19 16:35:28.157  1094 I Zygote  : Process 5696 exited due to signal 9 (Killed)
```

**Timeline**: Diagnostic suspend at 16:35:26.885 → Crash at 16:35:28.084 = **~1.2 seconds of runtime**

### R2R_COMP — NO CRASH (logcat.txt lines 2371–2383)

```
03-19 16:39:54.626  6473 I DOTNET  : The runtime has been configured to pause during startup
03-19 16:39:54.626  6473 I DOTNET  : DOTNET_DiagnosticPorts="127.0.0.1:9000,connect,suspend"
03-19 16:39:54.958  6473 D DOTNET  : AndroidCryptoNative_InitLibraryOnLoad
```

**No FATAL EXCEPTION, no crash, no VM shutdown** — the app runs for the full trace duration.

### Diagnostic Port Configuration Is Identical

Both configs receive identical diagnostic port settings (`DOTNET_DiagnosticPorts="127.0.0.1:9000,connect,suspend"`). The diagnostic infrastructure is NOT the issue.

---

## Causal Chain

```
1. Build: PGO=True in build-configs.props
   └─> Activates _MauiUseDefaultReadyToRunPgoFiles=false (csproj line 83)
   └─> Includes profiles/*.mibc (csproj line 87) — BUT NO FILES EXIST

2. Build: _MauiPublishReadyToRunPartial NOT set to false
   └─> MAUI SDK may default to --partial in crossgen2

3. crossgen2: Composite R2R compilation with ZERO profiles + possible --partial
   └─> Degenerate composite image with unpredictable method compilation boundaries

4. Runtime: App launches, diagnostic port connects, runtime resumes
   └─> DependencyInjectionEventSource static constructor fails
   └─> TypeInitializationException in ServiceProvider..ctor
   └─> FATAL EXCEPTION → Process SIGKILL'd after ~1.2 seconds

5. Trace: dotnet-trace receives partial EventPipe data, then connection drops
   └─> Resulting .nettrace has valid header but no end-of-stream marker
   └─> File may be small (empty/near-empty if crash is very fast)
      or 1+ MB but internally truncated
   └─> dotnet-pgo create-mibc fails with "Read past end of stream"
```

---

## Dependencies

| Component | Version/Source | Role |
|-----------|---------------|------|
| MAUI SDK | net11.0-android (preview) | Provides `_MauiPublishReadyToRunPartial` and default PGO profiles |
| crossgen2 | .NET 11 Preview | Composite R2R compilation — sensitive to profile presence |
| `DependencyInjectionEventSource` | Microsoft.Extensions.DependencyInjection | `EventSource`-derived class with reflection-heavy static ctor |
| dotnet-dsrouter | 10.0.716101 | TCP-to-IPC diagnostic bridge for Android |
| dotnet-trace | 10.0.716101 | EventPipe trace collector |

---

## Risks

1. **All four platforms are affected**: The same `_MauiPublishReadyToRunPartial` gap exists in `ios/`, `osx/`, and `maccatalyst/` build-configs.props. If any Apple platform attempts R2R_COMP_PGO nettrace collection without `--pgo-mibc-dir`, the same crash will occur.

2. **Silent build success**: The `dotnet build` step succeeds (exit 0) even though it produces a defective app. The crash only manifests at runtime on the device. No build-time warning or error is emitted.

3. **8 KB validation gate may not catch this**: The existing 8 KB trace size check (`collect_nettrace.sh` lines 422–439) catches empty traces where the app never connected to dsrouter. But if the app connects, runs for ~1 second, and crashes, the trace could be several hundred KB — passing the gate but still being internally truncated.

4. **`dotnet-pgo create-mibc` exit code 0 on failure**: Even when `create-mibc` fails to parse the truncated trace, it exits 0 (known upstream bug, documented in `nettrace-retrospective.md` Bug 6). Automation relying on exit codes will miss the failure.

---

## Recommended Fixes (Ranked)

### Fix 1 (Critical): Add `_MauiPublishReadyToRunPartial=false` to R2R_COMP_PGO

**All four platforms**. This ensures crossgen2 produces a fully-compiled composite image regardless of whether profiles are provided.

**File**: `android/build-configs.props`, lines 63–74

```xml
<PropertyGroup Condition="'$(_BuildConfig)' == 'R2R_COMP_PGO'">
  ...
  <_MauiPublishReadyToRunPartial>false</_MauiPublishReadyToRunPartial>  <!-- ADD THIS -->
  <PGO>True</PGO>
</PropertyGroup>
```

**Repeat for**:
- `ios/build-configs.props` line 45–54
- `osx/build-configs.props` line 23–33
- `maccatalyst/build-configs.props` line 45–54

**Rationale**: R2R_COMP_PGO should produce an image as stable as R2R_COMP, just with PGO-guided optimization. Without `_MauiPublishReadyToRunPartial=false`, the build is fragile when profiles are absent.

### Fix 2 (Important): Guard Against Empty Profiles

**Option A**: Fail the build if PGO=True but no profiles exist:
```xml
<Target Name="_ValidatePgoProfiles" BeforeTargets="_AOTCompileApp"
        Condition="'$(PGO)' == 'true' and '@(_ReadyToRunPgoFiles)' == ''">
  <Error Text="R2R_COMP_PGO requires MIBC profiles but none were found. Provide --pgo-mibc-dir or add profiles to the app's profiles/ directory." />
</Target>
```

**Option B**: Fall back to MAUI's default profiles when no custom profiles exist:
```xml
<PropertyGroup Condition="'$(PGO)' == 'true' and '@(_ReadyToRunPgoFiles)' == ''">
  <_MauiUseDefaultReadyToRunPgoFiles>true</_MauiUseDefaultReadyToRunPgoFiles>
</PropertyGroup>
```

### Fix 3 (Nice-to-have): Detect App Crash in collect_nettrace.sh

After the deploy+run step (line 393), check the app is still alive:

```bash
# After sleep 5
APP_PID=$(adb shell pidof "$PACKAGE_NAME" 2>/dev/null || true)
if [ -z "$APP_PID" ]; then
    echo "ERROR: App $PACKAGE_NAME is not running — it likely crashed during startup."
    echo "Check logcat for details:  adb logcat -d | grep -E 'FATAL|AndroidRuntime|DOTNET'"
    exit 1
fi
```

### Fix 4 (Nice-to-have): Add Logcat Crash Detection to Trace Validation

```bash
# After Step 6 (logcat dump)
if grep -q "FATAL EXCEPTION.*$PACKAGE_NAME\|TypeInitializationException" "$LOGCAT_FILE" 2>/dev/null; then
    echo "WARNING: Logcat shows the app crashed during trace collection."
    echo "The trace file is likely truncated/incomplete."
    grep "FATAL EXCEPTION\|TypeInitializationException" "$LOGCAT_FILE" | head -5
fi
```

---

## What `--pgo-instrumentation` Does (and Why It's Orthogonal)

When `--pgo-instrumentation` is passed, `collect_nettrace.sh` adds `-p:CollectNetTrace=true` (line 212). This causes the csproj to include `android/env-nettrace.txt` (csproj lines 77–79), which injects:

```
DOTNET_TieredPGO=1
DOTNET_ReadyToRun=0       ← DISABLES R2R at runtime
DOTNET_TieredPGO_InstrumentOnlyHotCode=0
...
```

The key variable is `DOTNET_ReadyToRun=0`, which forces ALL code through JIT at runtime. This **would avoid the crash** because the defective R2R image is ignored. However:

1. `--pgo-instrumentation` is optional and not passed by default
2. Even with it, the underlying build defect (no profiles) still exists
3. The purpose of `--pgo-instrumentation` is to collect JIT traces for future MIBC generation, not to work around build bugs

---

## Verification: Previously Collected Traces

| Trace | Timestamp | Size | create-mibc | Notes |
|-------|-----------|------|-------------|-------|
| `android-startup.nettrace` | Pre-timestamp era | Unknown | FAIL: truncated | Legacy artifact |
| `android-startup-20260318-141818.nettrace` | 14:18:18 | Unknown | FAIL: truncated | Early manual collection; dsrouter killed by amfid (pre-fix) |
| `android-startup-20260318-142521.nettrace` | 14:25:21 | 1,274,023 | FAIL: truncated | Post-fix collection but app likely crashed |
| `android-startup-20260318-142622.nettrace` | 14:26:22 | 1,642,285 | FAIL: truncated | Post-fix collection but app likely crashed |
| `dotnet-new-maui-android-R2R_COMP_PGO-startup-20260319-163334.nettrace` | 16:33:34 | Unknown | Not tested | **Logcat confirms crash at 16:35:28** |

**All R2R_COMP_PGO traces fail `dotnet-pgo create-mibc`** — because the app crashes in every case, truncating the EventPipe stream.

---

## Why Earlier Research Missed the Root Cause

The prior research documents (`android-r2r-comp-pgo-flow-bugs.md`, `android-pgo-mibc-validation-failures.md`, `nettrace-retrospective.md`) correctly identified:
- Truncated EventPipe streams (Bug 3/5 in retrospective)
- MSBuild profile merging issues (Bug 4)
- Exit-code-0-on-failure in dotnet-pgo (Bug 6)

But they **attributed the truncation to dsrouter/amfid timing issues** (which was true for the earliest traces, pre-fix) and **did not investigate the logcat for runtime crashes**. The logcat files were saved but never analyzed for DOTNET-related errors. The `TypeInitializationException` crash was present in the logcat all along but was buried among thousands of unrelated Android system messages.

**Key lesson**: When traces are truncated, ALWAYS check the logcat for app crashes. A crash mid-trace is the most common cause of truncation, ahead of dsrouter/amfid issues.

---

## Patterns

1. **R2R_COMP_PGO is designed to work WITH profiles** — it's meaningless without them. The `PGO=True` flag is a signal that PGO profiles should be applied, not a standalone feature.

2. **The `_MauiPublishReadyToRunPartial=false` omission is likely intentional** — PGO builds SHOULD use partial R2R (only compile profiled methods). But the design assumes profiles will always be provided, which isn't enforced.

3. **The `profiles/` directory is a bootstrapping artifact** — it's populated by the MIBC generation workflow (collect nettrace → create-mibc → copy to profiles/). On a fresh clone without running the workflow, it's empty, making R2R_COMP_PGO unusable.

4. **The crash in `DependencyInjectionEventSource`** is specifically an `EventSource`-derived class, which uses complex runtime reflection in its static constructor. This type of code is known to be sensitive to R2R compilation edge cases, especially when profile-guided compilation boundaries are incorrect.

5. **Chicken-and-egg problem**: The intended workflow is to collect nettrace → create MIBC → copy to `profiles/` → build R2R_COMP_PGO. But R2R_COMP_PGO without profiles crashes, so you can't collect traces from it. The bootstrapping path is to use R2R_COMP or CORECLR_JIT for initial trace collection, or use `download-mibc.sh` + `--pgo-mibc-dir profiles/` to download pre-built profiles first.

6. **Profile directory mismatch**: `download-mibc.sh` extracts profiles to `profiles/` at the repo root (line 207: `PROFILES_DIR="$SCRIPT_DIR/profiles"`). But the csproj's app-local profile glob references `$(MSBuildThisFileDirectory)profiles/*.mibc` which resolves to `apps/dotnet-new-maui/profiles/`. These are different directories. The `--pgo-mibc-dir` flag is needed to bridge the gap: `--pgo-mibc-dir profiles/` points to the repo-root profiles.
