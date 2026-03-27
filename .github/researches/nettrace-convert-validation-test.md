# Empirical Test: `dotnet-trace convert` Validation Behavior on Corrupt .nettrace Files

**Date**: 2025-06-16  
**Status**: SETUP VERIFIED — AWAITING EXECUTION  
**Prerequisite for**: Plan 009 (nettrace validation), `tools/validate-nettrace.sh` implementation

---

## Purpose

Determine whether `dotnet-trace convert` can serve as a reliable validation gate for `.nettrace` files. The critical unknown (from `nettrace-validation.md` §Risks #1): **does `dotnet-trace convert` exit non-zero on truncated/corrupt files, or does it silently succeed like `dotnet-pgo create-mibc` (Bug 6)?**

---

## Setup Verification (Confirmed)

### Tool Paths

| Component | Path | Verified |
|-----------|------|:--------:|
| dotnet-trace apphost | `tools/dotnet-trace` | ✅ exists (native MachO binary, 121.8 KB) |
| dotnet-trace DLL | `tools/.store/dotnet-trace/10.0.716701/dotnet-trace/10.0.716701/tools/net8.0/any/dotnet-trace.dll` | ✅ exists |
| .dotnet SDK | `.dotnet/dotnet` | ✅ exists |
| dotnet-trace version | 10.0.716701 | ✅ confirmed from directory structure |

**Note**: Plan 009 Task 1 references version `10.0.716101` — that's wrong. Actual version is **10.0.716701**.

### Test Files Available

| File | Role | Verified |
|------|------|:--------:|
| `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-142521.nettrace` | Valid trace (post-fix) | ✅ starts with `Nettrace` header |
| `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-142622.nettrace` | Valid trace (post-fix) | ✅ |
| `traces/dotnet-new-maui_R2R_COMP/android-startup.nettrace` | Valid trace | ✅ starts with `Nettrace` header |
| `traces/dotnet-new-maui_MONO_JIT/android-startup.nettrace` | Valid trace | ✅ starts with `Nettrace` header |
| `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-141818.nettrace` | Known-truncated (per research) | ✅ exists |
| `traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-20260318-141955.nettrace` | Known-truncated (per research) | ✅ exists |
| `traces/dotnet-new-maui_R2R_COMP_PGO_nettrace.nettrace` | ⚠️ MISLABELED — actually a binlog! | ❌ Not a real nettrace (starts with `BinLogFilePath`) |

### Header Verification

All real `.nettrace` files confirmed to start with:
- ASCII: `Nettrace` (8 bytes)
- Followed by: `!FastSerialization.1` (null-terminated)
- Then: `Trace` object with metadata blocks, event blocks, stack blocks

The mislabeled file `traces/dotnet-new-maui_R2R_COMP_PGO_nettrace.nettrace` starts with MSBuild binary log content — it's a `.binlog` with wrong extension.

---

## Test Plan

### Tests to Execute

| # | Test Case | Input | Expected Exit | Key Question |
|---|-----------|-------|:---:|---|
| 0 | `convert --help` | N/A | 0 | Does `convert` subcommand exist? |
| 1 | Valid .nettrace | Known-good trace file | 0 | Baseline: convert works at all |
| 2 | Truncated copy (50%) | `head -c <half>` of valid trace | **Non-zero?** | **THE KEY QUESTION** |
| 3 | Known-truncated trace | `android-startup-20260318-141818.nettrace` | **Non-zero?** | Same question, real-world file |
| 4 | Nettrace header + garbage | `printf 'Nettrace'` + 10 KB random | Non-zero | Detect garbage after valid header? |
| 5 | Completely wrong file | 50 KB random bytes | Non-zero | Reject non-nettrace entirely? |
| 6 | Empty file | 0 bytes | Non-zero | Reject empty files? |
| 7 | Tiny truncation (last 100 bytes removed) | `head -c <size-100>` of valid trace | **Non-zero?** | Detect subtle end-marker removal? |

### Execution

```bash
# From repo root:
chmod +x .github/researches/test-nettrace-convert.sh
bash .github/researches/test-nettrace-convert.sh 2>&1 | tee .github/researches/nettrace-convert-validation-test-output.txt
```

The script:
- Uses DLL execution mode (`$LOCAL_DOTNET $DOTNET_TRACE_DLL`) to avoid macOS `amfid` killing the apphost
- Falls back to apphost if DLL path isn't available
- Captures exit code, stdout, stderr, and output file size for every test
- Creates all synthetic test files in a temp directory
- Cleans up all temp files on exit (trap)
- Prints a structured summary

---

## Test Results

> **Status: NOT YET EXECUTED**
>
> Run the test script above and paste results here, or redirect output to
> `.github/researches/nettrace-convert-validation-test-output.txt`

### Test 0: `convert --help`

```
(pending)
```

### Test 1: Valid .nettrace

```
(pending)
```

### Test 2: Truncated copy (half size)

```
(pending)
```

### Test 3: Known-truncated trace

```
(pending)
```

### Test 4: Nettrace header + garbage

```
(pending)
```

### Test 5: Completely wrong binary file

```
(pending)
```

### Test 6: Empty file

```
(pending)
```

### Test 7: Tiny truncation (minus 100 bytes)

```
(pending)
```

---

## Analysis (To Complete After Execution)

### Critical Question: Is `dotnet-trace convert` reliable as a validation gate?

| Scenario | Outcome | Implication |
|----------|---------|-------------|
| Exit non-zero on truncation | ✅ **Best case** — can use exit code directly | Simple: `if ! dotnet-trace convert ...; then echo CORRUPT; fi` |
| Exit 0 but stderr has error text | ⚠️ **Workable** — must grep stderr | More fragile: pattern-match against known error strings |
| Exit 0, no stderr indicators | ❌ **Unusable** as validation gate | Need alternative approach (TraceEvent C# script, or check output size) |
| Exit 0 but output file is empty/tiny | ⚠️ **Partial** — can check output size | Compare output size to input size, reject if disproportionately small |

### Decision Matrix

Based on the results, update `nettrace-validation.md` § Summary table:

```
| `dotnet-trace convert` | ✅ | <result> | <result> | 1–3s | dotnet-trace | <recommendation> |
```

---

## Findings That Affect Plan 009

1. **Version number correction**: Plan 009 Task 1 step 3 references `10.0.716101`. Correct version is **10.0.716701**.

2. **Mislabeled file discovery**: `traces/dotnet-new-maui_R2R_COMP_PGO_nettrace.nettrace` is actually a binary log file, not a nettrace. Any file-discovery code that matches `*.nettrace` should validate the header magic, not just the extension.

3. **DLL execution preference**: Per `nettrace-validation.md` §Note on DLL Execution, prefer `$LOCAL_DOTNET $DOTNET_TRACE_DLL convert ...` over `$TOOLS_DIR/dotnet-trace convert ...` to avoid macOS `amfid` killing the apphost. The test script uses this approach.

---

## Key Files Referenced

| File | Relevance |
|------|-----------|
| `.github/researches/nettrace-validation.md` | Prior research — documents the unknown exit-code behavior |
| `.github/plans/009-nettrace-validation-plan.md` | Implementation plan that depends on this empirical test |
| `.github/researches/nettrace-retrospective.md` | Documents Bug 6: `dotnet-pgo` exits 0 on truncated traces |
| `.github/researches/test-nettrace-convert.sh` | **Test script created by this research** |
| `tools/dotnet-trace` | Apphost binary for dotnet-trace 10.0.716701 |
| `tools/.store/dotnet-trace/10.0.716701/.../dotnet-trace.dll` | DLL for dotnet-trace (preferred execution mode) |

---

*Research compiled: 2025-06-16*  
*Limitation: Shell command execution not available in research agent toolset. Test script created for manual execution.*
