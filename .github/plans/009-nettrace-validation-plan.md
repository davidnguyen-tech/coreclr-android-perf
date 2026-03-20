# Plan 009: Implement .nettrace Validation

## Overview

Add robust `.nettrace` file validation across all four platforms (Android, iOS, macOS, Mac Catalyst). Current validation is limited to file-size checks (8 KB on Android, 1 KB on Apple), which miss large-but-truncated files. Truncated nettrace files cause `Read past end of stream` errors in downstream consumers (`dotnet-pgo create-mibc`, TraceEvent analysis).

**Approach**: Create a shared `validate_nettrace()` shell function that performs:
1. Magic header check (`"Nettrace"` — 8 ASCII bytes)
2. Minimum size check (8 KB — catches empty/never-connected traces)
3. Full parse validation via `dotnet-trace convert` (catches truncation within valid-looking files)

Integrate this function into all four `collect_nettrace.sh` scripts and the `apple_measure_lib.sh` helper, replacing ad-hoc size checks with a single consistent codepath.

**Base branch**: `feature/apple-agents`  
**Research**: `.github/researches/nettrace-validation.md`

---

## Tasks

### Task 1: Empirically verify `dotnet-trace convert` behavior on truncated files
> **Status**: ☐ Not started  
> **Type**: Manual testing (no code changes — results inform subsequent tasks)

**Why first**: The research identifies a critical unknown — `dotnet-pgo create-mibc` exits 0 on truncated traces (Bug 6). We cannot assume `dotnet-trace convert` behaves differently. If `convert` also exits 0 on truncation, we need a fallback strategy (stderr grepping or a different approach). All subsequent tasks depend on knowing the exact behavior.

**Steps**:
1. Locate a known-truncated trace in `traces/` (per research: timestamps ≤141818 in `traces/dotnet-new-maui_R2R_COMP_PGO/`). If none exist locally, create one by truncating a valid trace: `dd if=valid.nettrace of=truncated.nettrace bs=1 count=50000`
2. Locate a known-valid trace (timestamps ≥142521, or any recent successful collection)
3. Run on truncated:
   ```bash
   tools/dotnet-trace convert <truncated.nettrace> --format speedscope --output /tmp/validate-test.json 2>&1
   echo "Exit code: $?"
   ```
4. Run on valid:
   ```bash
   tools/dotnet-trace convert <valid.nettrace> --format speedscope --output /tmp/validate-test-good.json 2>&1
   echo "Exit code: $?"
   ```
5. Also try DLL mode (the Android script prefers this to avoid amfid kills):
   ```bash
   .dotnet/dotnet tools/.store/dotnet-trace/10.0.716101/dotnet-trace/10.0.716101/tools/net8.0/any/dotnet-trace.dll convert <truncated.nettrace> --format speedscope --output /tmp/validate-test-dll.json 2>&1
   echo "Exit code: $?"
   ```

**Record**:
- Does `convert` exit non-zero on truncated file?  ☐ Yes  ☐ No
- Does `convert` print error text to stderr/stdout? ☐ Yes  ☐ No → if so, what pattern?
- Does `convert` produce an output file on failure?  ☐ Yes  ☐ No
- Does `convert` succeed on valid file (exit 0)?     ☐ Yes  ☐ No

**Decision gate**:
- If `convert` exits non-zero on truncation → use exit code as primary signal (simple)
- If `convert` exits 0 but prints error text → grep stderr for `"Read past end of stream"`, `"Exception"`, or `"Error"` (same pattern as `dotnet-pgo` workaround)
- If `convert` exits 0 with no error text → fall back to checking output file existence + size, or investigate `dotnet-pgo create-mibc` stderr-grep approach

**Acceptance**: Results documented in this plan (update the checkboxes above) before proceeding to Task 2.

---

### Task 2: Create shared `tools/validate-nettrace.sh`
> **Status**: ☐ Not started  
> **Type**: New file — single PR

**File**: `tools/validate-nettrace.sh`

**Design**: The script serves two purposes:
1. **Standalone CLI tool**: `./tools/validate-nettrace.sh <file.nettrace>` — validates any existing trace, useful for debugging
2. **Sourceable library**: Other scripts can `source tools/validate-nettrace.sh` and call `validate_nettrace <file>` as a function

**Function signature**:
```bash
# Validate a .nettrace file for completeness and structural integrity.
#
# Performs three checks in order:
#   1. Magic header: first 8 bytes must be ASCII "Nettrace"
#   2. Minimum size: file must be ≥ 8192 bytes (8 KB)
#   3. Full parse: dotnet-trace convert must succeed (catches truncation)
#
# Arguments:
#   $1 - Path to .nettrace file
#   $2 - (optional) "strict" — exit 1 on failure (default: return 1)
#
# Environment (must be set before calling):
#   DOTNET_TRACE_CMD — Full command to invoke dotnet-trace
#                      (e.g., "$LOCAL_DOTNET $DOTNET_TRACE_DLL" or "$TOOLS_DIR/dotnet-trace")
#
# Returns:
#   0 — Valid trace
#   1 — Invalid trace (diagnostic message printed to stderr)
validate_nettrace() { ... }
```

**Implementation notes**:
- **Magic header check**: `head -c 8 "$file" 2>/dev/null | tr -d '\0'` must equal `"Nettrace"`
- **Size check**: `wc -c < "$file" | tr -d ' '` must be ≥ 8192
- **Full parse**: Run `$DOTNET_TRACE_CMD convert "$file" --format speedscope --output "$temp_out" 2>"$temp_err"`. The exact success/failure detection depends on Task 1 results.
- **Temp file cleanup**: Use `trap` or explicit cleanup in both success and error paths. Use `mktemp "${TMPDIR:-/tmp}/nettrace-validate-XXXXXX.json"` (and `.err` for stderr capture)
- **Diagnostics**: On failure, print which check failed and why to stderr. Include file size and the specific error for troubleshooting.
- **Standalone mode**: At bottom of file, detect if script was executed (not sourced) and run validation on `$1`:
  ```bash
  # If executed directly (not sourced), validate the file passed as argument
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
      # Auto-detect DOTNET_TRACE_CMD from repo layout if not set
      ...
      validate_nettrace "$1" strict
  fi
  ```
- **DOTNET_TRACE_CMD**: When run standalone, auto-detect from repo layout (prefer DLL mode like `android/collect_nettrace.sh` does). When sourced, caller must set `DOTNET_TRACE_CMD` before calling.

**Key pattern to follow**: The DLL-vs-apphost preference from `android/collect_nettrace.sh:18-35`. On macOS, prefer `$LOCAL_DOTNET $DOTNET_TRACE_DLL` to avoid amfid killing the apphost during parsing.

**Acceptance criteria**:
- [ ] `./tools/validate-nettrace.sh valid.nettrace` exits 0 with "PASS" message
- [ ] `./tools/validate-nettrace.sh truncated.nettrace` exits 1 with diagnostic message
- [ ] `./tools/validate-nettrace.sh /dev/null` exits 1 (empty file)
- [ ] `./tools/validate-nettrace.sh /tmp/not-nettrace.txt` exits 1 (wrong magic)
- [ ] Can be sourced and `validate_nettrace` called as a function
- [ ] Temp files cleaned up on both success and failure paths
- [ ] Script is executable (`chmod +x`)

---

### Task 3: Integrate validation into `android/collect_nettrace.sh`
> **Status**: ☐ Not started  
> **Type**: Modify existing file — single PR  
> **Depends on**: Task 2

**File**: `android/collect_nettrace.sh`

**Current validation** (lines 422–439):
```bash
if [ -f "$TRACE_FILE" ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"
    if [ "$TRACE_SIZE" -lt 8192 ]; then
        echo "ERROR: Trace file is too small to be usable ..."
        exit 1
    fi
else
    echo "ERROR: No trace file was produced."
    exit 1
fi
```

**Changes**:
1. **Source the validation library** near the top of the file (after `source init.sh`, around line 8):
   ```bash
   source "$TOOLS_DIR/validate-nettrace.sh"
   ```

2. **Set `DOTNET_TRACE_CMD`**: Already computed as `$DOTNET_TRACE` (lines 31–35). Add after line 35:
   ```bash
   DOTNET_TRACE_CMD="$DOTNET_TRACE"
   ```
   (Or just export `DOTNET_TRACE` — but using a separate variable name avoids collision since `$DOTNET_TRACE` is used for `collect` elsewhere.)

3. **Replace the size-check block** (lines 422–439) with:
   ```bash
   if [ -f "$TRACE_FILE" ]; then
       TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
       echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"

       if ! validate_nettrace "$TRACE_FILE"; then
           echo "The app likely did not connect to dsrouter. Verify:"
           echo "  1. A device is connected:  adb devices"
           echo "  2. Port 9000 is not blocked:  lsof -i :9000"
           echo "  3. adb reverse is active:  adb reverse --list"
           exit 1
       fi
   else
       echo "ERROR: No trace file was produced."
       exit 1
   fi
   ```

**Key decisions**:
- The Android script already uses DLL mode for `DOTNET_TRACE`, so validation also runs in DLL mode (safe from amfid)
- Keep the Android-specific diagnostic hints (adb devices, port 9000, adb reverse) — they're platform-specific and should remain in the platform script, not in the shared function
- Validation failure is a **hard error** (exit 1) — same as current behavior for size check, but now also catches truncation

**Acceptance criteria**:
- [ ] A truncated trace causes exit 1 with clear error message
- [ ] A valid trace passes validation and script continues normally  
- [ ] Platform-specific adb debugging hints still appear on failure
- [ ] The `DOTNET_TRACE_CMD` variable is set before `validate_nettrace` is called

---

### Task 4: Integrate validation into Apple `collect_nettrace.sh` scripts (osx, maccatalyst)
> **Status**: ☐ Not started  
> **Type**: Modify existing files — single PR  
> **Depends on**: Task 2

**Files**:
- `osx/collect_nettrace.sh` (lines 261–272)
- `maccatalyst/collect_nettrace.sh` (lines 261–272)

These two scripts have **identical** validation blocks:
```bash
if [ -f "$TRACE_FILE" ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"
    if [ "$TRACE_SIZE" -lt 1000 ]; then
        echo "WARNING: Trace file is suspiciously small ($TRACE_SIZE bytes)."
        echo "The app may not have connected to the diagnostic port properly."
    fi
else
    echo "ERROR: No trace file was produced."
    exit 1
fi
```

**Changes for both files**:
1. **Source the validation library** after `source init.sh` (around line 7):
   ```bash
   source "$TOOLS_DIR/validate-nettrace.sh"
   ```

2. **Set `DOTNET_TRACE_CMD`**: These scripts set `DOTNET_TRACE="$TOOLS_DIR/dotnet-trace"` (line 17). Add after:
   ```bash
   DOTNET_TRACE_CMD="$DOTNET_TRACE"
   ```
   **Note**: Unlike Android, these scripts use the apphost directly. Consider switching to DLL mode here too for amfid safety. However, since macOS/maccatalyst apps run locally (no dsrouter), the trace duration is short and amfid risk is low. Keep apphost for now; revisit if we see amfid kills during validation.

3. **Replace the size-check block** with:
   ```bash
   if [ -f "$TRACE_FILE" ]; then
       TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
       echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"

       if ! validate_nettrace "$TRACE_FILE"; then
           echo "The app may not have connected to the diagnostic port properly."
           exit 1
       fi
   else
       echo "ERROR: No trace file was produced."
       exit 1
   fi
   ```

**Behavioral change**: Current Apple scripts only **warn** on small files (no exit 1). This changes to **hard error** on validation failure. This is intentional — a truncated trace is useless downstream. If the caller needs non-fatal behavior, they should handle the exit code.

**Acceptance criteria**:
- [ ] Both `osx/collect_nettrace.sh` and `maccatalyst/collect_nettrace.sh` updated identically
- [ ] Validation failure causes exit 1 (upgrade from warning)
- [ ] Valid traces pass and script continues

---

### Task 5: Integrate validation into `ios/collect_nettrace.sh`
> **Status**: ☐ Not started  
> **Type**: Modify existing file — single PR  
> **Depends on**: Task 2

**File**: `ios/collect_nettrace.sh` (lines 590–607)

The iOS script has a slightly different structure — it has platform-specific hint text for physical vs simulator:

```bash
if [ -f "$TRACE_FILE" ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"
    if [ "$TRACE_SIZE" -lt 1000 ]; then
        echo "WARNING: Trace file is suspiciously small ($TRACE_SIZE bytes)."
        if [ "$PLATFORM" = "ios" ]; then
            echo "The app may not have connected to dsrouter properly."
            echo "Check that a device is connected, port 9000 is not in use,"
            echo "and the app is signed with a development provisioning profile."
        else
            echo "The app may not have connected to the diagnostic port properly."
        fi
    fi
```

**Changes**:
1. **Source the validation library** after `source init.sh` (line 23):
   ```bash
   source "$TOOLS_DIR/validate-nettrace.sh"
   ```

2. **Set `DOTNET_TRACE_CMD`**: The script sets `DOTNET_TRACE="$TOOLS_DIR/dotnet-trace"` on line 33. Add after:
   ```bash
   DOTNET_TRACE_CMD="$DOTNET_TRACE"
   ```

3. **Replace the validation block** (lines 590–607) preserving the platform-specific diagnostics:
   ```bash
   if [ -f "$TRACE_FILE" ]; then
       TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
       echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"

       if ! validate_nettrace "$TRACE_FILE"; then
           if [ "$PLATFORM" = "ios" ]; then
               echo "The app may not have connected to dsrouter properly."
               echo "Check that a device is connected, port 9000 is not in use,"
               echo "and the app is signed with a development provisioning profile."
           else
               echo "The app may not have connected to the diagnostic port properly."
           fi
           exit 1
       fi
   else
       echo "ERROR: No trace file was produced."
       exit 1
   fi
   ```

**Acceptance criteria**:
- [ ] Validation failure causes exit 1 (upgrade from warning)
- [ ] Platform-specific hints preserved (physical device vs simulator)
- [ ] Valid traces pass and script continues

---

### Task 6: Integrate validation into `tools/apple_measure_lib.sh`
> **Status**: ☐ Not started  
> **Type**: Modify existing file — single PR  
> **Depends on**: Task 2

**File**: `tools/apple_measure_lib.sh`

The `collect_nettrace()` function (lines 1123–1168) accepts a trace file and copies it to a destination. It has a weak size check:

```bash
# Line 1132
if [ "$file_size" -gt 1000 ]; then
    cp "$expected_path" "$dest_path"
    ...
    return 0
else
    echo "Warning: Trace file at $expected_path is suspiciously small ($file_size bytes)." >&2
fi
```

And in the search fallback (line 1154):
```bash
found=$(find "$dir" -name "${name_pattern}*.nettrace" -size +1k 2>/dev/null | head -1)
```

**Changes**:
1. **Source the validation library** at the top of the file (after the double-source guard, around line 30). Note: this file is already a library — sourcing another library from it is fine as long as `TOOLS_DIR` is available (it's set by `init.sh` which callers must source first).
   ```bash
   source "${TOOLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/validate-nettrace.sh"
   ```

2. **Replace the size check in `collect_nettrace()`** (around line 1132):
   ```bash
   # Before:
   if [ "$file_size" -gt 1000 ]; then
       cp "$expected_path" "$dest_path"
   
   # After:
   if validate_nettrace "$expected_path" 2>/dev/null; then
       cp "$expected_path" "$dest_path"
   ```

3. **Update the search fallback**: Keep the `-size +1k` in `find` as a quick filter (avoids calling `validate_nettrace` on obviously empty files), but add validation after finding a candidate:
   ```bash
   found=$(find "$dir" -name "${name_pattern}*.nettrace" -size +1k 2>/dev/null | head -1)
   if [ -n "$found" ] && validate_nettrace "$found" 2>/dev/null; then
       ...
   ```

**Important**: `DOTNET_TRACE_CMD` must be set by the caller before using `collect_nettrace()`. The calling scripts (`osx/measure_osx_startup.sh`, `maccatalyst/measure_maccatalyst_startup.sh`, etc.) source both `init.sh` and `apple_measure_lib.sh`. They must also set `DOTNET_TRACE_CMD`. If they don't already, this needs to be added to those callers.

**Risk**: If `DOTNET_TRACE_CMD` is not set, `validate_nettrace` should fall back gracefully — skip the full-parse check and only do header + size checks. The function should handle this:
```bash
if [ -z "${DOTNET_TRACE_CMD:-}" ]; then
    echo "Warning: DOTNET_TRACE_CMD not set, skipping full parse validation" >&2
    return 0  # pass with header+size checks only
fi
```

**Acceptance criteria**:
- [ ] `collect_nettrace()` rejects truncated files (not just tiny ones)
- [ ] Search fallback also validates found files
- [ ] Graceful degradation when `DOTNET_TRACE_CMD` is not set
- [ ] Callers of `collect_nettrace()` still work correctly

---

## Dependencies

```
Task 1 (verify dotnet-trace convert behavior)
  │
  ▼
Task 2 (create tools/validate-nettrace.sh)
  │
  ├──▶ Task 3 (android/collect_nettrace.sh)
  ├──▶ Task 4 (osx + maccatalyst collect_nettrace.sh)
  ├──▶ Task 5 (ios/collect_nettrace.sh)
  └──▶ Task 6 (tools/apple_measure_lib.sh)
```

- **Task 1 → Task 2**: Must know `dotnet-trace convert` exit code behavior before writing the validation function
- **Task 2 → Tasks 3–6**: All integration tasks depend on the shared function existing
- **Tasks 3, 4, 5, 6**: Independent of each other — can be done in parallel or any order. Grouping into fewer PRs is fine (e.g., Tasks 4+5 together since they're all Apple platforms).

**Suggested PR grouping**:
- **PR 1**: Tasks 1+2 — Create and test the shared validation function
- **PR 2**: Task 3 — Android integration
- **PR 3**: Tasks 4+5+6 — All Apple platform integration

---

## Testing Strategy

### Unit Testing (Task 2)

Create test cases using synthetic nettrace files:

| Test Case | Input | Expected |
|-----------|-------|----------|
| Valid trace | Any successful collection from `traces/` | Exit 0, "PASS" |
| Empty file | `touch /tmp/empty.nettrace` | Exit 1, "wrong header" |
| Wrong magic | `echo "NotTrace" > /tmp/bad.nettrace` | Exit 1, "wrong header" |
| Too small (valid header) | `printf 'Nettrace' > /tmp/tiny.nettrace` | Exit 1, "too small" |
| Truncated (large, valid header) | `dd if=valid.nettrace of=trunc.nettrace bs=1 count=50000` | Exit 1, "truncated or corrupt" |
| Non-existent file | `/tmp/does-not-exist.nettrace` | Exit 1, error |

### Integration Testing (Tasks 3–6)

For each platform, verify:
1. **Happy path**: Run a normal `collect_nettrace.sh` invocation → trace collected and validated
2. **Failure path**: Manually replace the collected trace with a truncated version before validation runs → script exits 1

### Regression Testing

- Ensure `measure_all.sh` still works end-to-end on at least one platform
- Ensure the PGO pipeline (`R2R_COMP_PGO` builds that consume traces) still works when traces are valid

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| `dotnet-trace convert` exits 0 on truncated files (like `dotnet-pgo`) | Cannot use exit code as signal; need stderr grep fallback | Task 1 tests this empirically. Fallback: grep stderr for `"Read past end of stream\|Exception"` + check output file size |
| `dotnet-trace convert` is slow on large traces | Adds 1–5 seconds per collection | Acceptable for startup traces (0.5–2 MB). For PGO instrumentation traces, may need to skip full parse or add `--skip-validation` flag |
| macOS `amfid` kills apphost during validation | Validation itself fails intermittently | Apple scripts currently use apphost for `DOTNET_TRACE`. Switch to DLL mode (like Android) if amfid kills observed. Low risk since validation parse is fast (< 3s) |
| `DOTNET_TRACE_CMD` not set in all callers | `validate_nettrace` called without ability to do full parse | Graceful degradation: skip full parse, do header+size only, log warning |
| Behavioral change: Apple scripts upgrade from warning to hard error on bad traces | Scripts that previously continued despite bad traces now fail | Intentional. A truncated trace is useless downstream. Callers should re-collect. |
| Plan 007 (Fix 2) overlaps with this plan | Conflicting changes to `android/collect_nettrace.sh` validation block | This plan supersedes Plan 007 Fix 2. If Plan 007 Fix 2 has already been applied, Task 3 should replace its changes. Check git log. |

---

## Decisions & Trade-offs

1. **Single shared function vs. per-platform validation**: Chose shared function in `tools/validate-nettrace.sh`. Avoids code duplication. The function is parameterized by `DOTNET_TRACE_CMD` to handle DLL-vs-apphost differences.

2. **Hard error vs. warning on validation failure**: Chose hard error (exit 1) for all platforms. A truncated trace has no valid downstream use case — better to fail fast than produce garbage MIBC or measurements.

3. **`dotnet-trace convert` format**: Using `speedscope` format because it requires iterating all events (per research). `chromium` would also work. Speedscope JSON output is lightweight.

4. **DOTNET_TRACE_CMD as environment variable (not function argument)**: Keeps function signature simple. The calling script already computes the dotnet-trace invocation for collection; reusing it for validation is natural.

5. **Standalone + sourceable dual-mode for `validate-nettrace.sh`**: Enables both interactive debugging (`./tools/validate-nettrace.sh traces/foo.nettrace`) and programmatic integration. Follows a common shell pattern.

---

## Lessons

(To be updated as implementation progresses)
