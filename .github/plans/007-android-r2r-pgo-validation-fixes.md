# Android R2R_COMP_PGO Validation Fixes — Minimal Local Plan

## Overview

Two coordinated fixes for Android R2R_COMP_PGO to ensure external MIBC profiles genuinely replace (not merge with) app-local profiles, and add minimal validation to catch truncated nettrace files.

**Scope**: Unpushed local fixes only. No new features, no over-engineering.

---

## Minimal Fix Steps

### Fix 1: Override App-Local Profiles When External MIBC Dir Is Provided

**Issue**: `android/build-workarounds.targets` adds external MIBC files to `_ReadyToRunPgoFiles` ItemGroup **alongside** (not replacing) app-local profiles from `generate-apps.sh`. Both get passed to crossgen2, defeating validation intent.

**Files to modify**:
1. `android/build-workarounds.targets` — Add property flag when `PgoMibcDir` is set
2. `generate-apps.sh` — Conditionally suppress app-local profiles based on flag

**Implementation**:

**File 1: `android/build-workarounds.targets`** (after line 41, before closing `</Project>`)  
Add a new PropertyGroup that sets a flag when external MIBC is provided:
```xml
<!-- When external MIBC dir is provided, signal to app csproj to suppress app-local profiles -->
<PropertyGroup Condition="'$(TargetPlatformIdentifier)' == 'android'
                          And '$(PublishReadyToRun)' == 'true'
                          And '$(PublishReadyToRunComposite)' == 'true'
                          And '$(PGO)' == 'true'
                          And '$(PgoMibcDir)' != ''">
  <PgoMibcDirOverridesAppLocal>true</PgoMibcDirOverridesAppLocal>
</PropertyGroup>
```

**File 2: `generate-apps.sh`** (lines 164–166 and 172–174)  
Update both MAUI and non-MAUI ItemGroup conditions to exclude app-local profiles when flag is set:
```
From: Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'"
To:   Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true' and '$(PgoMibcDirOverridesAppLocal)' != 'true'"
```

**Acceptance**: When `--pgo-mibc-dir /path/to/mibc` is passed, `crossgen2` receives ONLY files from `/path/to/mibc`, not app-local profiles. (Verify via binlog or crossgen2 verbose output.)

---

### Fix 2: Add Minimal Nettrace Validation Before Use

**Issue**: Collected `.nettrace` files may be truncated (e.g., dsrouter disconnect, buffer loss), causing downstream `dotnet-pgo create-mibc` to fail with `Read past end of stream`. No detection at collection time.

**File to modify**: `android/collect_nettrace.sh`

**Implementation**: After line 434 (existing trace file size check), add:
```bash
# Validate trace is not corrupted by checking for reasonable size.
# EventPipe binary format with recorded events typically >10KB;
# smaller traces suggest incomplete collection.
# This is a practical gate to avoid feeding truncated traces to create-mibc.
if [ "$TRACE_SIZE" -lt 10000 ]; then
    echo "WARNING: Trace file is very small ($TRACE_SIZE bytes)."
    echo "  This may indicate incomplete collection:"
    echo "  - App did not run long enough to generate events"
    echo "  - Dsrouter connection dropped before trace completed"
    echo "  - EventPipe providers did not emit startup events"
    echo ""
    echo "Recommend re-running collection or checking adb logcat:"
    cat "$LOGCAT_FILE" 2>/dev/null | tail -20 || true
fi
```

**Acceptance**: User is alerted before passing trace to create-mibc. Threshold of 10KB is practical (normal startup traces are 100KB+; incomplete traces are typically <5KB).

---

## Files Requiring Changes

| File | Change Type | Lines | Reason |
|------|------------|-------|--------|
| `android/build-workarounds.targets` | Add PropertyGroup | After 41 | Set override flag when external MIBC provided |
| `generate-apps.sh` | Update conditions (2×) | 164, 172 | Suppress app-local profiles when override flag set |
| `android/collect_nettrace.sh` | Add validation | After 434 | Warn on suspiciously small trace files |

---

## Validation Checkpoints

1. **Fix 1 verification**:
   - Build with: `./android/collect_nettrace.sh dotnet-new-maui R2R_COMP_PGO --pgo-mibc-dir /path/to/external/mibc`
   - Inspect binlog or run with `-v:d` and confirm `_ReadyToRunPgoFiles` contains **only** `/path/to/external/mibc/*.mibc` items, not app-local `profiles/` files
   - Build succeeds and APK compiles with external profiles

2. **Fix 2 verification**:
   - Simulate truncated trace: `dd if=traces/*/android-startup-*.nettrace bs=1 count=1000 of=/tmp/short.nettrace`
   - Mock a manual trace collection scenario with undersized file and verify warning is printed
   - Normal collection (file >10KB) proceeds without warning

---

## Dependencies & Ordering

1. **Fix 1 must be complete before Fix 2** — No hard dependency, but logically:
   - Fix 1 ensures external MIBC is used (affects build correctness)
   - Fix 2 is defensive validation (affects user experience)
   - Apply Fix 1 first to unblock real flow validation

2. **Both changes are local, unpushed** — No integration or CI impact until pushed

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| MSBuild property name collision | Use unique prefix `PgoMibcDirOverridesAppLocal`; check `grep -r "PgoMibcDir" .` to confirm no conflicts |
| App-local profiles still used if only one file updated | Add cross-reference comments: `build-workarounds.targets` → "See `generate-apps.sh:164,172`"; commit message links both |
| 10KB threshold too aggressive/lenient | Threshold chosen based on typical EventPipe startup traces (100KB+); 10KB is conservative lower bound. Adjust empirically if needed. |
| Trace validation incomplete | This is **intentional**: only size check, no deep parsing. Full EventPipe validation belongs in downstream `dotnet-pgo` tool, not collection script. |

---

## Testing Strategy

### Manual Test Case 1: External MIBC Override
```bash
# 1. Collect MIBC externally (or use existing external dir)
EXTERNAL_MIBC=/tmp/test-mibc-external
mkdir -p "$EXTERNAL_MIBC"
cp profiles/DotNet_Maui_Android.mibc "$EXTERNAL_MIBC/"

# 2. Apply Fix 1 changes to code

# 3. Build with external MIBC
cd apps/dotnet-new-maui
dotnet build -c Release \
  -f net9.0-android \
  -r android-x64 \
  -p:_BuildConfig=R2R_COMP_PGO \
  -p:PgoMibcDir="$EXTERNAL_MIBC"

# 4. Verify only external MIBC was used (check binlog diagnostics)
# Expected: _ReadyToRunPgoFiles lists ONLY "$EXTERNAL_MIBC/DotNet_Maui_Android.mibc"
```

### Manual Test Case 2: Trace Size Validation
```bash
# 1. Apply Fix 2 to collect_nettrace.sh

# 2. Run normal collection (should proceed without warning)
./android/collect_nettrace.sh dotnet-new-maui R2R_COMP_PGO

# 3. Verify large trace (>10KB) is accepted:
ls -lh traces/dotnet-new-maui_R2R_COMP_PGO/
# Expected: file size in MBs, no "WARNING" in output

# 4. Simulate undersized trace and verify warning:
mkdir -p /tmp/test-trace
dd if=/dev/zero bs=1 count=1000 of=/tmp/test-trace/test.nettrace
# (Manually inspect collect_nettrace.sh logic to confirm it would warn on <10KB file)
```

---

## Lesson Implications

**No new lessons needed for this fix.** This is a straightforward MSBuild property coordination + defensive validation, following existing patterns.

However: The root cause (ItemGroup merging instead of replacement) reinforces that **MSBuild ItemGroup += semantics are implicit**. Always explicitly Remove/Clear when overriding derived items.

---

## Success Criteria

- [ ] Build with `--pgo-mibc-dir` demonstrably uses external MIBC only (verified via binlog)
- [ ] Collection script warns on <10KB traces
- [ ] Both MAUI and non-MAUI apps build correctly with Fix 1
- [ ] Unpushed, local-only changes (no commits until approved)
