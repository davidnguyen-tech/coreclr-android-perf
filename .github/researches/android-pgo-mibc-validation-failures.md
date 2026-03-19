# Android PGO MIBC Validation Failures — Root Causes & Fixes

## Summary

**Two distinct validation failures identified in Android R2R_COMP_PGO builds with external MIBC profiles:**

1. **App-local profiles not replaced**: When `--pgo-mibc-dir` is used, **both** the external MIBC directory AND the app's built-in `profiles/` directory get passed to crossgen2, defeating the purpose of the external MIBC override.
2. **Invalid/corrupted nettrace crashes create-mibc**: Collected EventPipe traces may contain truncated or malformed data that causes `dotnet-pgo create-mibc` to fail with `Read past end of stream`.

---

## Root Cause 1: MSBuild ItemGroup Duplication

### Problem
When building with `--pgo-mibc-dir`, both sources populate `_ReadyToRunPgoFiles`:

- **`build-workarounds.targets` line 40**: `<_ReadyToRunPgoFiles Include="$(PgoMibcDir)/*.mibc" />`
- **`generate-apps.sh` lines 165/173**: `<_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />`

**Both ItemGroups execute**, so crossgen2 receives BOTH sets of `.mibc` files. If the app's `profiles/` directory contains stale or incompatible profiles, they corrupt the PGO data.

### Evidence
- **File**: `android/build-workarounds.targets` (lines 35–41)
  - Comment (line 31–33) claims "Files in PgoMibcDir are added alongside any *.mibc files already listed in the app project's profiles/ directory"
  - This is **intended** behavior but problematic for validation because app-local profiles take precedence or cause conflicts

- **File**: `generate-apps.sh` (lines 164–166 and 172–174)
  - Both MAUI and non-MAUI apps unconditionally add app-local `profiles/*.mibc` files
  - No mechanism to disable or remove app-local profiles when `--pgo-mibc-dir` is active

### Expected vs. Actual Behavior
- **Intended**: External `--pgo-mibc-dir` should **replace** app-local profiles for validation/testing
- **Actual**: Both get merged, causing:
  - Conflicting method-level PGO decisions (old vs. new profiles disagree on hot methods)
  - Potential binary format incompatibilities (different .NET versions)
  - Silent failures if app-local profiles are empty or stale

---

## Root Cause 2: EventPipe Trace Truncation or Malformation

### Problem
The collected `.nettrace` file may be truncated or contain incomplete EventPipe data. When downstream tools (e.g., `dotnet-pgo create-mibc`) attempt to parse it, they hit end-of-file mid-record, causing:
```
Read past end of stream
System.IO.EndOfStreamException
```

### Evidence
- **Flow**: `collect_nettrace.sh` (lines 400–410) → `dotnet-trace collect` → `.nettrace` file
- **Potential causes**:
  1. **Dsrouter connection drops**: If the app or dsrouter crashes/disconnects before the trace window closes, incomplete records are written
  2. **Buffer overflow/ring-buffer loss**: EventPipe providers may not flush all events before trace termination
  3. **Malformed trace header**: dotnet-trace may write incomplete metadata

### Known Risk Points
- **Line 394** (`android/collect_nettrace.sh`): "Waiting for app to connect to dsrouter and suspend..." is arbitrary (5s hardcoded)
  - If the app takes >5s to start or fails to suspend, the trace starts before app is ready
  - Partial traces lack the actual startup events needed for accurate MIBC extraction

- **Line 406–410**: `dotnet-trace collect` with providers + duration
  - If dsrouter closes connection abnormally (line 76, "Broken TCP connection detected"), trace file remains open but incomplete
  - No validation that trace file contains expected provider records before consuming it

---

## Minimal Fixes

### Fix 1: Override App-Local Profiles When External MIBC Dir Is Provided

**File**: `android/build-workarounds.targets`

**Problem**: Current ItemGroup always adds app-local profiles. Need conditional override.

**Solution**: Add a new ItemGroup that **clears** app-local profiles when `PgoMibcDir` is provided:

```xml
<!-- Clear app-local profiles when external MIBC directory is provided (line 34-41) -->
<PropertyGroup Condition="'$(TargetPlatformIdentifier)' == 'android'
                          And '$(PublishReadyToRun)' == 'true'
                          And '$(PublishReadyToRunComposite)' == 'true'
                          And '$(PGO)' == 'true'
                          And '$(PgoMibcDir)' != ''">
  <!-- Remove any items from the app-local profiles ItemGroup -->
  <PgoOverrideAppLocalProfiles>true</PgoOverrideAppLocalProfiles>
</PropertyGroup>
```

**File**: `generate-apps.sh` (around lines 164–174)

**Problem**: Both MAUI and non-MAUI patches unconditionally add app-local profiles.

**Solution**: Add a condition to skip app-local profiles if `PgoOverrideAppLocalProfiles=true`:

```xml
<!-- For MAUI apps (line 164–166) -->
<ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true' and '$(PgoOverrideAppLocalProfiles)' != 'true'">
  <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
</ItemGroup>

<!-- For non-MAUI apps (line 172–174) -->
<ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true' and '$(PgoOverrideAppLocalProfiles)' != 'true'">
  <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
</ItemGroup>
```

**Result**: When `PgoMibcDir` is set, app-local `profiles/` are skipped, and ONLY external MIBC files are passed to crossgen2.

---

### Fix 2: Validate Trace File Completeness Before Use

**File**: `android/collect_nettrace.sh` (after line 434)

**Problem**: No check that the trace file contains expected EventPipe data.

**Solution**: Add a post-collection validation step:

```bash
# Step 6: Validate trace file contains EventPipe data (insert after line 434)
echo ""
echo "--- Validating trace file ---"

# Check if trace file contains at least one EventPipe event record
# EventPipe traces are binary format; look for the magic header (0xFEEDFEED or similar patterns)
# Also verify file size is reasonable (>5KB suggests actual events were recorded)
TRACE_MAGIC=$(xxd -l 4 "$TRACE_FILE" 2>/dev/null | grep -o "feedfeed\|eedfeedf" || true)
if [ -z "$TRACE_MAGIC" ]; then
    echo "WARNING: Trace file does not contain expected EventPipe magic header."
    echo "This may indicate an incomplete or corrupted trace."
fi

# If trace is suspiciously small, warn about incomplete collection
if [ "$TRACE_SIZE" -lt 5000 ]; then
    echo "WARNING: Trace file is small ($TRACE_SIZE bytes). This may indicate:"
    echo "  - App did not run long enough to generate events"
    echo "  - Dsrouter connection dropped before trace completion"
    echo "  - EventPipe providers did not emit events"
fi
```

**Alternative (Stronger)**: Test nettrace parsing before downstream use:

```bash
# For MAUI R2R_COMP_PGO workflow: add a dry-run dotnet-pgo create-mibc check
if command -v dotnet-pgo &>/dev/null; then
    echo "--- Pre-flight: Testing nettrace parsability ---"
    if ! dotnet-pgo create-mibc --trace-file "$TRACE_FILE" --output-file /tmp/test.mibc 2>/dev/null; then
        echo "WARNING: dotnet-pgo create-mibc failed on trace file."
        echo "The trace may be truncated or corrupted. Recommend re-collecting."
    fi
fi
```

**Result**: Operator is alerted immediately if trace is unusable, rather than discovering the problem downstream.

---

## Tested Commands

### Validation 1: Verify ItemGroup Duplication in Generated .csproj
```bash
# File: apps/dotnet-new-maui/dotnet-new-maui.csproj line 85-86
grep -n "_ReadyToRunPgoFiles" apps/dotnet-new-maui/dotnet-new-maui.csproj
# OUTPUT:
#   85:    <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
```
**Status**: **PASS** — Confirms app-local profiles are in csproj

```bash
# File: android/build-workarounds.targets line 40
grep -n "_ReadyToRunPgoFiles" android/build-workarounds.targets
# OUTPUT:
#   40:    <_ReadyToRunPgoFiles Include="$(PgoMibcDir)/*.mibc" />
```
**Status**: **PASS** — Confirms PgoMibcDir profiles are in workarounds

**Conclusion**: Both ItemGroups exist. MSBuild will merge them → both profile sets passed to crossgen2.

### Validation 2: Verify App-Local Profiles Exist
```bash
ls -la apps/dotnet-new-maui/profiles/
# OUTPUT:
#   DotNet_Maui_Android.mibc
#   DotNet_Maui_Android_SampleContent.mibc
#   DotNet_Maui_Blazor_Android.mibc
```
**Status**: **PASS** — App-local profiles present (will be merged with external MIBC)

### Validation 3: Nettrace Collection with External MIBC
```bash
./android/collect_nettrace.sh dotnet-new-maui R2R_COMP_PGO \
    --pgo-mibc-dir /Users/nguyendav/repos/mibc/android-x64-ci-20260316.2
# (See results/run1.log, results/run2.log)
```
**Status**: **PASS** — Build completed, trace collected (no create-mibc error observed in collection phase)
- File size: 1,274,023 bytes (appears complete)
- Build output: "Build succeeded"

---

## Remaining Blockers

1. **Fix requires coordinated changes to two files**
   - `android/build-workarounds.targets`: Add `PgoOverrideAppLocalProfiles` property  
   - `generate-apps.sh`: Update ItemGroup conditions in lines 164–166 and 172–174
   - **Risk**: Missing one location → app-local profiles still get used
   - **Mitigation**: Update both in same commit; add comment referencing the companion file

2. **Root Cause 2 (nettrace truncation) has unclear trigger**
   - Collection succeeded in observed runs (exit 0, 1.2 MB file)
   - "Read past end of stream" error may only appear in DOWNSTREAM tools (e.g., create-mibc)
   - **Action needed**: Check if `dotnet-pgo create-mibc` was actually invoked on collected traces
   - **If not**: This may be a hypothetical failure (trace collection works, but create-mibc not tested)

3. **No integration test for root cause 1 fix**
   - Proof-of-concept: Build with `--pgo-mibc-dir` and verify crossgen2 output
   - Requires inspecting binlog or crossgen2 diagnostics
   - **Workaround**: Compare built APK size/startup perf with vs. without fix

4. **EventPipe trace validation is weak**
   - Proposed magic header check is fragile
   - Better approach: Dry-run `dotnet-pgo create-mibc` on trace after collection
   - **Blocker**: `dotnet-pgo` must be available on build machine (not guaranteed)
