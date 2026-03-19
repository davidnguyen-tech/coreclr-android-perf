# Android R2R_COMP_PGO Flow Bugs — Root Cause Research

## Issue (1): External MIBC Not Replacing App-Local Profiles

### Root Cause

**Two-source population of `_ReadyToRunPgoFiles` with no Remove.**

The `_ReadyToRunPgoFiles` MSBuild item is populated from **two independent sources**:

1. **`apps/dotnet-new-maui/dotnet-new-maui.csproj` lines 85–87** — unconditional include of
   app-local profiles when PGO + composite R2R is active:
   ```xml
   <ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
     <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
   </ItemGroup>
   ```
   This adds `profiles/DotNet_Maui_Android.mibc`, `DotNet_Maui_Android_SampleContent.mibc`,
   `DotNet_Maui_Blazor_Android.mibc` unconditionally — no guard on `$(PgoMibcDir)`.

2. **`android/build-workarounds.targets` lines 35–41** — conditional APPEND of external MIBC
   when `PgoMibcDir` is set:
   ```xml
   <ItemGroup Condition="... And '$(PgoMibcDir)' != ''">
     <_ReadyToRunPgoFiles Include="$(PgoMibcDir)/*.mibc" />
   </ItemGroup>
   ```
   This **appends** to whatever was already in `_ReadyToRunPgoFiles`. There is no `Remove`.

The `_MauiUseDefaultReadyToRunPgoFiles=false` guard (csproj line 83) only prevents MAUI's
SDK-internal default profiles — it has zero effect on the csproj's own explicit include above.

**Net result:** When `--pgo-mibc-dir` is passed, crossgen2 receives ALL files from BOTH
`profiles/*.mibc` (3 app-local) AND `PgoMibcDir/*.mibc` (N external). The external path is
passed and consumed, but alongside the app-local ones, not instead of them.

### Where the bug lives

| File | Line | Code | Role |
|------|------|------|------|
| `apps/dotnet-new-maui/dotnet-new-maui.csproj` | 82–87 | `_MauiUseDefaultReadyToRunPgoFiles=false` + `Include profiles/*.mibc` | Adds local profiles unconditionally |
| `android/build-workarounds.targets` | 35–41 | `Include $(PgoMibcDir)/*.mibc` | Appends external, no Remove |

### Why "external path not proving consumption"

The binlog (written to `traces/dotnet-new-maui_R2R_COMP_PGO/dotnet-new-maui_R2R_COMP_PGO_nettrace.binlog`
and `verify-profile-consumption.binlog`) would show BOTH sets of mibc passed to crossgen2. The
verify build (`verify-profile-consumption.diag.log`, 37 MB, detailed verbosity) was run **without**
`-p:PgoMibcDir=...`, so it only reflects app-local profiles. No diagnostic log captured the
external-MIBC run in a way that lists the actual files passed to crossgen2.

---

## Issue (2): `Read past end of stream` During ETLX / create-mibc

### Root Cause

**The specific traces tested are TRUNCATED — the EventPipe end-of-stream marker was never written.**

The ETLX failure path:
```
System.Exception: Read past end of stream.
  at FastSerialization.IOStreamStreamReader.Fill(Int32 minimum)
  at FastSerialization.Deserializer.ReadObject()
  at Microsoft.Diagnostics.Tracing.EventPipeEventSource.Process()
  at TraceLog.CopyRawEvents(...)
```

`EventPipeEventSource.Process()` reads EventPipe blocks sequentially until it hits an
EndObject marker. "Read past end of stream" at this level is the canonical signature of
a **truncated EventPipe file** — the stream contains valid blocks but no final end marker.
This is distinct from a format-version mismatch, which would produce "Unknown object type"
or "Version X not supported."

The partial ETLX file (`android-startup.nettrace.etlx`) was created DURING a failed conversion.
Its existence confirms that serialization started (file was opened and data was written) but
the process threw before reaching the end, yielding an incomplete ETLX.

### Which traces failed vs. which have not been tested

| Trace file | Collection time | create-mibc tested | Result |
|---|---|---|---|
| `android-startup.nettrace` | Unknown (pre-timestamp era) | YES | FAIL — truncated |
| `android-startup-20260318-141818.nettrace` | 14:18:18 | YES | FAIL — truncated |
| `android-startup-20260318-141955.nettrace` | 14:19:55 | NO | unknown |
| `android-startup-20260318-142521.nettrace` | 14:25:21 (run1) | NO | unknown |
| `android-startup-20260318-142622.nettrace` | 14:26:22 (run2) | NO | unknown |

The two traces that failed (`android-startup` and `141818`) were collected **before
`run_collection.sh` was created** (run_collection.sh shows run1 starting at 14:25:21).
The `141818` trace is 7 minutes before run1 — an early/manual collection attempt.

The newer traces from `run_collection.sh` (`142521` = 1,274,023 bytes, `142622` = 1,642,285 bytes)
were confirmed by run1.log/run2.log to have completed cleanly ("Trace completed." reported by
dotnet-trace, 60-second duration). **They have not been tested with dotnet-pgo and may work fine.**

### Why the older traces are truncated

The `141818` trace was likely an interrupted early collection. The `android-startup.nettrace`
(no timestamp) is a legacy trace from the pre-timestamping naming era — its collection conditions
are unknown but it is the smallest/oldest artifact in the directory.

Critically: `collect_nettrace.sh` (around the `141818`-era) had dsrouter started BEFORE the build,
meaning long R2R builds (~40s) could cause amfid to kill dsrouter before the app ever launched.
If dsrouter died mid-session, the EventPipe stream would be truncated without its end marker.
The current script starts dsrouter AFTER the build (comment at line 301: "This avoids amfid
killing dsrouter during long R2R builds"), which is why the newer traces are clean.

### Secondary issue: missing `--pgo-instrumentation` in `run_collection.sh`

`run_collection.sh` does NOT pass `--pgo-instrumentation`:
```bash
"$SCRIPT_DIR/android/collect_nettrace.sh" "$APP" "$CONFIG" \
    --pgo-mibc-dir "$MIBC_DIR"    # <-- no --pgo-instrumentation
```

Without `--pgo-instrumentation`, the app runs with R2R code active (`DOTNET_ReadyToRun=0`
is NOT set). The `env-nettrace.txt` (added via `-p:CollectNetTrace=true`) sets
`DOTNET_ReadyToRun=0` to force JIT so methods appear in JIT event streams. Without this,
an R2R_COMP_PGO build runs its AOT-compiled native code — JIT events are sparse and the
resulting MIBC would have poor method coverage.

---

## Recommended Minimal Fixes

### Fix 1 — Issue (1): Remove app-local profiles when `PgoMibcDir` is set

**Option A (preferred): patch `android/build-workarounds.targets`**

Replace the current ItemGroup (lines 35–41) with:

```xml
<ItemGroup Condition="'$(TargetPlatformIdentifier)' == 'android'
                      And '$(PublishReadyToRun)' == 'true'
                      And '$(PublishReadyToRunComposite)' == 'true'
                      And '$(PGO)' == 'true'
                      And '$(PgoMibcDir)' != ''">
  <!-- Remove project-local profiles so only the external MIBC dir is used -->
  <_ReadyToRunPgoFiles Remove="@(_ReadyToRunPgoFiles)" />
  <_ReadyToRunPgoFiles Include="$(PgoMibcDir)/*.mibc" />
</ItemGroup>
```

The `Remove="@(_ReadyToRunPgoFiles)"` clears whatever the csproj added before the
targets file runs (Directory.Build.targets executes after the project file's ItemGroups).

**Option B (alternative): gate the csproj include on PgoMibcDir being empty**

In `apps/dotnet-new-maui/dotnet-new-maui.csproj` change line 85 from:
```xml
<ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
```
To:
```xml
<ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true' and '$(PgoMibcDir)' == ''">
```

Option A is cleaner since it keeps all external-MIBC logic in `build-workarounds.targets` and
doesn't require modifying each app's csproj.

### Fix 2 — Issue (2): Point create-mibc at the correct (non-truncated) traces

**Step A:** Test the newer traces first. Run dotnet-pgo on `142521.nettrace` or `142622.nettrace`:
```bash
# (from repo root, using global dotnet-pgo or sdk-local equivalent)
dotnet-pgo create-mibc \
  --trace traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-142521.nettrace \
  --output traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-142521.mibc \
  --reference apps/dotnet-new-maui/obj/Release/net11.0-android/android-arm64/linked \
  2>&1 | tee traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-142521.create-mibc.log
```

If this succeeds, the issue is only with the older truncated traces, not the collection flow itself.

**Step B:** Add `--pgo-instrumentation` to `run_collection.sh` so future traces capture JIT events
with R2R disabled, yielding higher-quality MIBC data:
```bash
"$SCRIPT_DIR/android/collect_nettrace.sh" "$APP" "$CONFIG" \
    --pgo-mibc-dir "$MIBC_DIR" \
    --pgo-instrumentation   # <-- ADD THIS
```

This is a quality fix — MIBC from traces without PGO instrumentation will have incomplete
coverage because R2R code runs natively without generating JIT compilation events.

---

## Exact Commands Tested (PASS/FAIL)

All testing was static analysis (file inspection + log review). No commands were executed by
this researcher. The following command results were inferred from existing log artifacts:

| Command | Source artifact | Observed result |
|---|---|---|
| `dotnet-pgo create-mibc --trace android-startup.nettrace` | `android-startup.create-mibc.log` | FAIL — `Read past end of stream` |
| `dotnet-pgo create-mibc --trace android-startup-20260318-141818.nettrace` | `android-startup-20260318-141818.create-mibc.log` | FAIL — `Read past end of stream` |
| `./run_collection.sh` (run1, trace=142521) | `results/run1.log` | PASS — "Trace completed.", 1,274,023 bytes |
| `./run_collection.sh` (run2, trace=142622) | `results/run2.log` | PASS — "Trace completed.", 1,642,285 bytes |
| `dotnet build -p:_BuildConfig=R2R_COMP_PGO` (no PgoMibcDir) | `verify-profile-consumption.diag.log` | PASS — build succeeded, but app-local profiles only |
| `dotnet-pgo create-mibc --trace 142521.nettrace` | NOT YET RUN | unknown |
| `dotnet-pgo create-mibc --trace 142622.nettrace` | NOT YET RUN | unknown |

---

## Lesson Candidate

**Failing verification is only as valid as the artifact under test.** The "integrity/create-mibc
path" ran dotnet-pgo on OLD truncated traces instead of the NEW traces produced by the
validated collection flow. The failure reported a real bug (truncated EventPipe stream) but
in the WRONG artifacts — the new traces were never tested. Always ensure that validation steps
target the EXACT artifacts produced by the workflow under validation, not leftover artifacts
from earlier exploratory runs.

A corollary: when a directory contains timestamped AND non-timestamped versions of the same
artifact (e.g., `android-startup.nettrace` and `android-startup-20260318-142521.nettrace`),
the non-timestamped one is almost always a legacy artifact from before the convention was
established. Do not use it as a reference for current flow validation.

---

## Remaining Blockers

1. **dotnet-pgo not installed in repo tools.** The `plan.md` references
   `tools/dotnet-pgo` (doesn't exist) and `/Users/nguyendav/.dotnet/tools/dotnet-pgo`
   (access denied for directory listing). Must verify dotnet-pgo is available before running
   create-mibc validation against the newer traces.

2. **External MIBC path not confirmed accessible.** `/Users/nguyendav/repos/mibc/android-x64-ci-20260316.2`
   was referenced in `run_collection.sh` and `collection_summary.txt`, but the directory
   listing returned "Permission denied". Cannot confirm how many `.mibc` files it contains
   or their platform/runtime compatibility.

3. **RID mismatch concern (android-x64 vs android-arm64).** The external MIBC dir is named
   `android-x64-ci-20260316.2` but the build target is `android-arm64`. The MIBC files
   from an x64 training run cannot guide crossgen2 for arm64 R2R compilation — method tokens
   may match but native code hints are arch-specific. This may be intentional (x64 profiles
   used as method-selection hints for arm64 composite) or a misconfiguration. Needs explicit
   confirmation from the build owner.

4. **MIBC quality unknown without `--pgo-instrumentation`.** The run_collection.sh traces
   were collected without forcing JIT re-execution. If create-mibc succeeds on 142521/142622,
   the resulting MIBC may have low method coverage. Add `--pgo-instrumentation` to
   run_collection.sh before using the traces for production MIBC generation.
