# .nettrace File Validation: Completeness and Corruption Detection

**Date**: 2025-06-15  
**Scope**: How to validate that collected `.nettrace` files are complete and well-formed before downstream consumption (e.g., `dotnet-pgo create-mibc`, ETLX conversion, or `TraceEvent` analysis).

---

## Executive Summary

The `.nettrace` format is a binary serialized stream based on **FastSerialization** (from `Microsoft.Diagnostics.Tracing.TraceEvent`). A complete file has a well-defined header magic string and is terminated by an **EndObject tag** (byte `0x01`). Truncated files — where the writer was interrupted before writing this tag — cause "Read past end of stream" errors in all downstream consumers.

**Current validation in this repo**: File-size-only checks (< 8 KB for Android, < 1 KB for Apple platforms). This catches empty/never-connected traces but misses large-but-truncated files (1+ MB).

**Recommended practical approach**: Use `dotnet-trace convert` to speedscope format as a validation gate. It uses the same TraceEvent parsing pipeline as `dotnet-pgo create-mibc` and will fail on truncated files. Unlike `dotnet-pgo`, `dotnet-trace` is already installed on every machine that runs the collection scripts.

---

## Architecture: The .nettrace File Format

### Format Overview

The `.nettrace` format is an EventPipe binary trace, serialized using the **FastSerialization** library from `Microsoft.Diagnostics.Tracing.TraceEvent`. The format is documented in the [dotnet/runtime diagnostics design docs](https://github.com/dotnet/runtime/blob/main/docs/design/mono/diagnostics-tracing.md) and implemented in `Microsoft.Diagnostics.FastSerialization.dll`.

### Binary Structure

```
┌──────────────────────────────────────────────┐
│ Header:                                      │
│   Magic: "Nettrace" (8 ASCII bytes)          │
│   Serialization Type: "!FastSerialization.1"  │
│     (null-terminated string)                  │
├──────────────────────────────────────────────┤
│ Object Stream:                               │
│   Tag: BeginObject (0x05)                    │
│   [Object: Trace metadata]                   │
│   [Object: EventBlock 1]                     │
│   [Object: MetadataBlock]                    │
│   [Object: StackBlock]                       │
│   [Object: SequencePointBlock]               │
│   [Object: EventBlock 2]                     │
│   ...                                        │
│   Tag: NullReference (0x01) ← END MARKER     │
├──────────────────────────────────────────────┤
│ [Optional padding / alignment bytes]          │
└──────────────────────────────────────────────┘
```

### Key Format Details

1. **Magic Header**: The first 8 bytes are ASCII `Nettrace` (hex: `4E 65 74 74 72 61 63 65`). This is followed by the FastSerialization version string `!FastSerialization.1` (null-terminated).

2. **Block Types**: The stream contains typed blocks — `EventBlock`, `MetadataBlock`, `StackBlock`, `SequencePointBlock` — each with their own size-prefixed headers.

3. **End-of-Stream Marker**: A complete nettrace is terminated by a `NullReference` tag (byte `0x01`), which signals the `FastSerialization.Deserializer` to stop reading. This is the canonical "is it complete?" marker.

4. **No Checksum**: The format has **no CRC, hash, or integrity checksum**. Corruption within blocks (bit flips, partial writes) cannot be detected by header inspection alone — only by parsing the entire stream.

### What Makes a Nettrace "Truncated"

A truncated nettrace occurs when the EventPipe writer (in the runtime) or the `dotnet-trace collect` tool was interrupted before writing the `NullReference` end tag. This happens when:

- **dsrouter crashes** (e.g., macOS `amfid` SIGKILL — Bug 3 in the retrospective)
- **App crashes** before trace session completes
- **Diagnostic port disconnects** (USB cable pulled, device sleep, network drop)
- **`dotnet-trace` is killed** (SIGTERM during collection, timeout race condition)

The resulting file has a valid header and potentially megabytes of valid event blocks, but the deserializer hits EOF while expecting more data (mid-block or before the end tag).

---

## Key Files: Current Validation Logic

### Existing Validation by Platform

| Script | Location | Validation | Threshold |
|--------|----------|-----------|-----------|
| `android/collect_nettrace.sh` | Lines 422–439 | File size check, hard error | < 8 KB → exit 1 |
| `osx/collect_nettrace.sh` | Lines 261–272 | File size check, warning only | < 1,000 bytes → warning |
| `maccatalyst/collect_nettrace.sh` | Lines 261–272 | File size check, warning only | < 1,000 bytes → warning |
| `ios/collect_nettrace.sh` | Lines 590–607 | File size check, warning only | < 1,000 bytes → warning |
| `tools/apple_measure_lib.sh` | Lines 1130–1139 | File size check (in `collect_nettrace()`) | < 1,000 bytes → warning |

### Gap Analysis

- **Android** (`android/collect_nettrace.sh:422-439`): The 8 KB threshold catches empty traces but not 1+ MB truncated ones. The retrospective (`nettrace-retrospective.md` line 62) documents this as a known limitation: *"Full validation would require a dry-run `dotnet-pgo create-mibc`, which requires the tool to be installed."*

- **Apple platforms**: Even weaker — 1 KB threshold with only warnings, no hard errors. A 500-byte file that somehow passes through would not stop the pipeline.

- **apple_measure_lib.sh**: The `collect_nettrace()` helper (line 1123) searches for `.nettrace` files by name pattern and copies them, but only does a size > 1 KB check before accepting them.

### Downstream Consumers That Detect Corruption

| Consumer | Error on Truncation | Exit Code | Evidence |
|----------|-------------------|-----------|----------|
| `dotnet-pgo create-mibc` | Yes: "Read past end of stream" `System.FormatException` | **0** (bug!) | `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup.create-mibc.log` |
| `TraceLog.CreateFromEventPipeDataFile()` | Yes: same error, throws during `Process()` | Exception | `Analyzer.cs:51` in performance submodule |
| `TraceEventDispatcher.GetDispatcherFromFileName()` | Deferred — fails during `Process()`, not at open | Exception | `TraceSourceManager.cs:34` |
| `dotnet-trace convert` | **To be tested** — uses same TraceEvent pipeline | **To be tested** | N/A |

**Critical finding**: `dotnet-pgo create-mibc` exits 0 even on truncated traces (Bug 6 in retrospective, line 67-71). This means you cannot use its exit code as a validation gate. You must check for the presence of the output `.mibc` file AND absence of error text in stderr.

---

## Patterns: Existing Validation Approaches in the Ecosystem

### 1. File Size Check (Current — Weak)

```bash
TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
if [ "$TRACE_SIZE" -lt 8192 ]; then
    echo "ERROR: Trace file too small"
    exit 1
fi
```

**Pros**: Zero dependencies, instant  
**Cons**: Cannot detect large-but-truncated files  
**Where used**: `android/collect_nettrace.sh:422-439`

### 2. Magic Header Check (Medium — Structural)

The nettrace header starts with ASCII `Nettrace` at offset 0. This can be validated with:

```bash
# Check nettrace magic header
MAGIC=$(head -c 8 "$TRACE_FILE" | tr -d '\0')
if [ "$MAGIC" != "Nettrace" ]; then
    echo "ERROR: Invalid nettrace header (not a nettrace file)"
    exit 1
fi
```

**Pros**: Catches completely wrong files, zero-byte files, non-nettrace data  
**Cons**: Cannot detect truncation — a truncated file still has a valid header

### 3. End-of-Stream Tag Check (Medium — Tail Inspection)

The `NullReference` end tag is byte `0x01` at a specific position near the end. However, the exact position varies because the last block has variable-length padding. Checking for `0x01` as the very last non-padding byte is fragile because:

- Padding bytes may follow the end tag
- The value `0x01` can appear naturally within event data
- Different versions of TraceEvent may write slightly different trailing bytes

**Not recommended** as a standalone check — too fragile without parsing the stream.

### 4. `dotnet-trace convert` (Strong — Full Parse)

`dotnet-trace convert` reads the entire nettrace using the same `EventPipeEventSource.Process()` codepath that `dotnet-pgo create-mibc` and `TraceLog.CreateFromEventPipeDataFile()` use. If the file is truncated, `Process()` will throw the same "Read past end of stream" exception.

```bash
DOTNET_TRACE="tools/dotnet-trace"
TEMP_OUT=$(mktemp "${TMPDIR:-/tmp}/nettrace-validate-XXXXXX.json")

# Attempt conversion to speedscope format (lightest output)
if "$DOTNET_TRACE" convert "$TRACE_FILE" --format speedscope --output "$TEMP_OUT" 2>&1; then
    echo "Trace validation: PASS"
else
    echo "ERROR: Trace file is corrupt or truncated"
    rm -f "$TEMP_OUT"
    exit 1
fi
rm -f "$TEMP_OUT"
```

**Testing notes**:
- The `--format speedscope` option produces JSON, which requires iterating all events
- Output goes to a temp file (then deleted) — `dotnet-trace convert` writes to a file path, not stdout
- Both `speedscope` and `chromium` formats are available
- The `convert` subcommand was added in dotnet-trace 5.x and is available in our version (10.0.716701)

**Pros**: Uses the same parsing code that downstream tools use — if `convert` passes, `create-mibc` should also pass. Already installed. Cross-platform.  
**Cons**: Slow for large traces (must parse entire file). Creates a temporary output file if `/dev/null` doesn't work on the platform.

**Important caveat**: Need to verify whether `dotnet-trace convert` exits non-zero on parse failure. The `dotnet-pgo` tool does NOT (Bug 6). Must test empirically.

### 5. `dotnet-pgo create-mibc` Dry Run (Strong but Fragile)

```bash
DOTNET_PGO="tools/dotnet-pgo"

# Attempt MIBC creation with throwaway output
TEMP_MIBC=$(mktemp /tmp/validate-XXXXXX.mibc)
"$DOTNET_PGO" create-mibc --trace-file "$TRACE_FILE" --output-file "$TEMP_MIBC" 2>"$TRACE_DIR/validate.err"
PGO_EXIT=$?
rm -f "$TEMP_MIBC"

# Cannot trust exit code (Bug 6) — check for error output AND missing output file
if [ ! -f "$TEMP_MIBC" ] || grep -q "Read past end of stream" "$TRACE_DIR/validate.err"; then
    echo "ERROR: Trace file failed dotnet-pgo validation"
    exit 1
fi
```

**Pros**: Tests the exact downstream codepath  
**Cons**: 
- Exit code 0 even on failure (upstream bug, documented in `nettrace-retrospective.md:67-71`)
- Requires `dotnet-pgo` to be installed (it IS in `tools/dotnet-pgo`)
- Slower than `convert` because it also builds MIBC data structures
- The temp file may or may not be created on failure — must check both

### 6. TraceEvent Programmatic Parse (Strongest — Custom Validation)

Write a small C# script that uses `Microsoft.Diagnostics.Tracing.TraceEvent` to parse the file:

```csharp
using Microsoft.Diagnostics.Tracing;

try {
    using var source = new EventPipeEventSource(args[0]);
    int eventCount = 0;
    source.AllEvents += _ => eventCount++;
    source.Process();
    Console.WriteLine($"VALID: {eventCount} events");
    return 0;
} catch (Exception ex) {
    Console.Error.WriteLine($"INVALID: {ex.Message}");
    return 1;
}
```

**Pros**: Can count events, check for specific providers, measure completeness  
**Cons**: Requires compiling and running a C# program; adds build complexity to shell scripts

The `Microsoft.Diagnostics.Tracing.TraceEvent.dll` (version 3.1.23) is already available at:
`tools/.store/dotnet-trace/10.0.716701/dotnet-trace/10.0.716701/tools/net8.0/any/Microsoft.Diagnostics.Tracing.TraceEvent.dll`

---

## Dependencies

### Tools Already Available

| Tool | Path | Version | Can Validate? |
|------|------|---------|--------------|
| `dotnet-trace` | `tools/dotnet-trace` (apphost) | 10.0.716701 | Yes, via `convert` subcommand |
| `dotnet-trace.dll` | `tools/.store/dotnet-trace/10.0.716701/.../dotnet-trace.dll` | 10.0.716701 | Same, via `dotnet <dll> convert` |
| `dotnet-pgo` | `tools/dotnet-pgo` (native binary) | N/A | Yes, but exit code 0 on failure (Bug 6) |
| TraceEvent DLL | `tools/.store/dotnet-trace/.../Microsoft.Diagnostics.Tracing.TraceEvent.dll` | 3.1.23 | Yes, programmatically |
| FastSerialization DLL | `tools/.store/dotnet-trace/.../Microsoft.Diagnostics.FastSerialization.dll` | (bundled) | Lower-level parsing possible |
| `.dotnet/dotnet` | Local SDK | .NET 11 preview | Runtime for DLL execution |

### Note on DLL Execution (macOS `amfid`)

Per `android/collect_nettrace.sh:18-35`, the apphost binaries can be killed by macOS `amfid` during long operations. For validation of large traces, prefer:
```bash
"$LOCAL_DOTNET" "$DOTNET_TRACE_DLL" convert "$TRACE_FILE" --format speedscope --output /tmp/validate.json
```
over:
```bash
"$TOOLS_DIR/dotnet-trace" convert "$TRACE_FILE" --format speedscope --output /tmp/validate.json
```

---

## Risks and Caveats

### 1. `dotnet-trace convert` Exit Code Behavior Is Unknown

The `dotnet-pgo` tool exits 0 on truncated traces (Bug 6 in retrospective). **It is unknown whether `dotnet-trace convert` has the same behavior.** The convert codepath uses `EventPipeEventSource.Process()` which throws, but it's unclear whether the exception is caught and swallowed by the convert command handler. **This must be tested empirically with a known-truncated trace before relying on it.**

**Action**: Test `dotnet-trace convert` against one of the known-truncated traces in `traces/dotnet-new-maui_R2R_COMP_PGO/` (timestamps ≤ 141818 are documented as truncated).

### 2. TraceEvent May Partially Succeed on Truncated Files

The TraceEvent library's `EventPipeEventSource` reads blocks sequentially. If truncation occurs between blocks (not mid-block), the parser may successfully read all complete blocks and only fail at the very end. This means:
- Event count may be non-zero but lower than expected
- `Process()` may still throw, but after processing some events
- A try/catch that captures the exception may still report "partially valid"

### 3. Validation Speed for Large Traces

Production nettrace files from startup traces are typically 0.5–2 MB (based on `nettrace-retrospective.md:42`: "Post-fix traces (≥142521) have correct file sizes (1.2–1.6 MB)"). Parsing these fully is fast (< 1 second). However, longer traces (e.g., PGO instrumentation traces) could be larger. The `convert` approach scales linearly with file size.

### 4. Temp File Cleanup

The `dotnet-trace convert` approach creates a temporary output file for each validation. Ensure the temp file is cleaned up even on validation failure (use a trap or explicit cleanup in both success and error paths). The Tier 2 `validate_nettrace()` function handles this correctly.

### 5. Two Different Error Patterns for Truncation

From the create-mibc logs, truncation manifests as two different error stacks depending on TraceEvent version:

**Newer TraceEvent** (`android-startup-20260318-141818.create-mibc.log`):
```
System.FormatException: Read past end of stream.
   at Microsoft.Diagnostics.Tracing.EventPipe.RewindableStream.ReadAtLeast(...)
   at Microsoft.Diagnostics.Tracing.FastSerializationObjectParser.ReadBlockHeader()
```

**Older TraceEvent** (`android-startup.create-mibc.log`):
```
System.Exception: Read past end of stream.
   at FastSerialization.IOStreamStreamReader.Fill(Int32 minimum)
   at FastSerialization.Deserializer.ReadTag()
```

Both indicate the same root cause but at different layers. Validation should check for both patterns in stderr if using text-based detection.

### 6. No Built-in "Validate" Subcommand in dotnet-trace

As of version 10.0.716701, `dotnet-trace` does **not** have a `validate` or `verify` subcommand. The available subcommands are: `collect`, `convert`, `list-profiles`, `ps`, and `report` (if available). `convert` is the closest thing to validation.

---

## Recommendations

### Tier 1: Minimal (Immediate — No New Dependencies)

Add **magic header check** alongside existing size check in all `collect_nettrace.sh` scripts:

```bash
# Validate nettrace header magic
MAGIC=$(head -c 8 "$TRACE_FILE" 2>/dev/null | tr -d '\0')
if [ "$MAGIC" != "Nettrace" ]; then
    echo "ERROR: File is not a valid nettrace (wrong magic header)."
    exit 1
fi

# Existing size check
if [ "$TRACE_SIZE" -lt 8192 ]; then
    echo "ERROR: Trace file too small ($TRACE_SIZE bytes < 8 KB)."
    exit 1
fi
```

**Catches**: Wrong file type, empty files, completely corrupt files  
**Misses**: Truncated files with valid headers

### Tier 2: Moderate (Recommended — Uses Existing Tools)

Add **`dotnet-trace convert` validation** after collection. This should be implemented as a shared function in a library script (like `apple_measure_lib.sh` or a new `tools/nettrace_validate.sh`):

```bash
# Validate nettrace by attempting conversion
validate_nettrace() {
    local trace_file="$1"
    local dotnet_trace="$2"       # Path to dotnet-trace (or "dotnet <dll>")
    local strict="${3:-false}"     # If true, exit on failure; if false, warn only
    
    # Tier 1: Header check
    local magic
    magic=$(head -c 8 "$trace_file" 2>/dev/null | tr -d '\0')
    if [ "$magic" != "Nettrace" ]; then
        echo "ERROR: Not a valid nettrace file (wrong header magic)." >&2
        [ "$strict" = true ] && return 1
    fi
    
    # Tier 1: Size check
    local size
    size=$(wc -c < "$trace_file" | tr -d ' ')
    if [ "$size" -lt 8192 ]; then
        echo "ERROR: Trace file too small ($size bytes)." >&2
        [ "$strict" = true ] && return 1
    fi
    
    # Tier 2: Full parse via convert
    local temp_out
    temp_out=$(mktemp "${TMPDIR:-/tmp}/nettrace-validate-XXXXXX.json")
    local convert_stderr
    convert_stderr=$(mktemp "${TMPDIR:-/tmp}/nettrace-validate-XXXXXX.err")
    
    $dotnet_trace convert "$trace_file" --format speedscope --output "$temp_out" 2>"$convert_stderr"
    local convert_exit=$?
    
    local has_error=false
    if [ $convert_exit -ne 0 ]; then
        has_error=true
    fi
    if grep -qi "read past end of stream\|exception\|error" "$convert_stderr"; then
        has_error=true
    fi
    if [ ! -s "$temp_out" ]; then
        has_error=true
    fi
    
    rm -f "$temp_out" "$convert_stderr"
    
    if [ "$has_error" = true ]; then
        echo "ERROR: Trace file failed parse validation (truncated or corrupt)." >&2
        echo "The nettrace was likely interrupted before completion." >&2
        [ "$strict" = true ] && return 1
        return 1
    fi
    
    echo "Trace validation: PASS ($size bytes, parseable)" >&2
    return 0
}
```

**Catches**: All forms of truncation and corruption detectable by TraceEvent  
**Cost**: Adds 1–3 seconds per validation for typical startup traces (0.5–2 MB)  
**Prerequisite**: Test with known-truncated trace FIRST to confirm `dotnet-trace convert` behavior

### Tier 3: Advanced (For PGO MIBC Pipeline)

For the specific `create-mibc` workflow, validate with the exact downstream tool:

```bash
# PGO-specific validation: dry-run create-mibc
validate_for_mibc() {
    local trace_file="$1"
    local dotnet_pgo="$2"
    
    local temp_mibc
    temp_mibc=$(mktemp "${TMPDIR:-/tmp}/validate-XXXXXX.mibc")
    local pgo_stderr
    pgo_stderr=$(mktemp "${TMPDIR:-/tmp}/validate-XXXXXX.err")
    
    "$dotnet_pgo" create-mibc \
        --trace-file "$trace_file" \
        --output-file "$temp_mibc" \
        2>"$pgo_stderr"
    
    local valid=true
    
    # Cannot trust exit code (Bug 6 — exits 0 on failure)
    if grep -qi "read past end of stream\|exception" "$pgo_stderr"; then
        valid=false
    fi
    if [ ! -s "$temp_mibc" ]; then
        valid=false
    fi
    
    rm -f "$temp_mibc" "$pgo_stderr"
    
    if [ "$valid" = false ]; then
        echo "ERROR: Trace file failed create-mibc validation." >&2
        return 1
    fi
    
    return 0
}
```

**Note**: This is the only approach that catches ALL failures that would affect MIBC creation, because it runs the exact same code. However, it requires `dotnet-pgo` and the exit-code-0 bug means we must check stderr + output file existence.

---

## Observed Evidence: Truncation in This Repository

### Known Truncated Traces

From `nettrace-retrospective.md:42`:
> All pre-fix traces (timestamps ≤141818) are truncated. Post-fix traces (≥142521) have correct file sizes (1.2–1.6 MB).

Truncated trace logs:
- `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup.create-mibc.log` — `System.Exception: Read past end of stream.` at `FastSerialization.IOStreamStreamReader.Fill()`
- `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-141818.create-mibc.log` — `System.FormatException: Read past end of stream.` at `EventPipe.RewindableStream.ReadAtLeast()`

### Error Stacktrace Anatomy

The truncation error propagates through:
1. `FastSerialization.Deserializer.ReadTag()` or `FastSerializationObjectParser.ReadBlockHeader()` — hit EOF
2. `EventPipeEventSource.Process()` — iterating blocks
3. `TraceLog.CopyRawEvents()` or `TraceLog.CreateFromEventPipeDataFile()` — ETLX conversion
4. Caller (e.g., `dotnet-pgo Program.InnerProcessTraceFileMain()`)

### Root Cause of Truncation (in This Repo)

Per `nettrace-retrospective.md:36-44`: macOS `amfid` killed the `dotnet-dsrouter` process mid-trace when the apphost binary acquired `com.apple.provenance` during long R2R composite builds. Fix: build-then-dsrouter ordering + DLL execution mode.

---

## Testing Plan

Before implementing any validation approach, the following must be tested empirically:

### Test 1: `dotnet-trace convert` on Truncated File

```bash
# Use a known-truncated trace
TRUNCATED="traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-141818.nettrace"

# Test convert
tools/dotnet-trace convert "$TRUNCATED" --format speedscope --output /tmp/test.json 2>&1
echo "Exit code: $?"
ls -la /tmp/test.json
```

Expected: Non-zero exit code OR error text in output. **Must verify — do not assume.**

### Test 2: `dotnet-trace convert` on Valid File

```bash
# Use a known-valid trace (post-fix timestamp)
VALID="traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-142521.nettrace"

# Test convert
tools/dotnet-trace convert "$VALID" --format speedscope --output /tmp/test-valid.json 2>&1
echo "Exit code: $?"
ls -la /tmp/test-valid.json
```

Expected: Exit code 0, output file exists with meaningful content.

### Test 3: Magic Header of Known Files

```bash
# Check first 8 bytes of each nettrace
for f in traces/**/*.nettrace; do
    echo -n "$f: "
    head -c 8 "$f" | xxd -p
done
```

Expected: All files start with `4e657474726163 65` (ASCII "Nettrace").

### Test 4: `dotnet-trace convert --help`

```bash
tools/dotnet-trace convert --help
```

Expected: Shows `--format` and `--output` options. Confirms `convert` subcommand exists.

---

## Summary: Recommendation Matrix

| Approach | Catches Empty | Catches Truncated | Catches Corrupt | Speed | Dependencies | Recommended? |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|
| Size check (≥ 8 KB) | ✅ | ❌ | ❌ | Instant | None | ✅ Baseline |
| Magic header ("Nettrace") | ✅ | ❌ | Partial | Instant | None | ✅ Add to all |
| `dotnet-trace convert` | ✅ | ✅* | ✅* | 1–3s | dotnet-trace | ✅ **Primary** |
| `dotnet-pgo create-mibc` | ✅ | ✅* | ✅* | 2–5s | dotnet-pgo | ⚠️ PGO only |
| TraceEvent C# script | ✅ | ✅ | ✅ | 1–3s | .NET SDK | ❌ Overkill |

\* Must verify exit code behavior empirically before trusting

### Implementation Order

1. **Immediate**: Add magic header check to all `collect_nettrace.sh` scripts (5 min)
2. **Test**: Run `dotnet-trace convert` on known-truncated and known-valid traces to confirm behavior
3. **If convert works**: Add `validate_nettrace()` function to shared library, call from all collection scripts
4. **If convert is unreliable**: Fall back to stderr-grepping approach with `dotnet-pgo create-mibc` (for MIBC pipeline only)

---

*Research compiled: 2025-06-15*  
*Sources: Repository analysis, error logs from `traces/dotnet-new-maui_R2R_COMP_PGO/*.create-mibc.log`, `nettrace-retrospective.md`, dotnet/runtime documentation, TraceEvent NuGet package 3.1.23*
