# Plan 001: Fix Secondary Bugs in Apple Measurement Scripts

## Overview

Fix two low-risk bugs that exist independently of the timing methodology issue.
These are small, safe changes that should ship first to clean up the codebase before
the more complex timing fixes.

**Bug A:** Missing `obj/` cleanup in macOS and Mac Catalyst scripts causes stale
intermediate build artifacts when switching between build configs.

**Bug B:** Duplicate `"APP size:"` output in all three Apple scripts causes
`measure_all.sh` to parse multi-line values, corrupting `summary.csv`.

---

## Files to Modify

| File | Bug |
|------|-----|
| `osx/measure_osx_startup.sh` | A (line 156) + B (line 205) |
| `maccatalyst/measure_maccatalyst_startup.sh` | A (line 157) + B (line 206) |
| `ios/measure_simulator_startup.sh` | B (line 338) |

---

## Sub-steps

### A. Add `obj/` cleanup to macOS and Mac Catalyst build steps

**Context:** `measure_startup.sh` (line 201) and `ios/measure_simulator_startup.sh`
(line 289) both clean `bin/` AND `obj/` before building. The macOS and Mac Catalyst
scripts only clean `bin/`.

1. **`osx/measure_osx_startup.sh` line 156** — Change:
   ```bash
   rm -rf "${APP_DIR:?}/bin"
   ```
   To:
   ```bash
   rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"
   ```

2. **`maccatalyst/measure_maccatalyst_startup.sh` line 157** — Same change:
   ```bash
   rm -rf "${APP_DIR:?}/bin"
   ```
   To:
   ```bash
   rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"
   ```

### B. Remove duplicate `"APP size:"` output

**Context:** Each script prints `"APP size: X MB (Y bytes)"` in two places:
- Once after locating the `.app` bundle (informational, mid-script)
- Once at the very end alongside `"Generic Startup | avg | min | max"` (for parsing)

`measure_all.sh` lines 163-164 use `grep "$PLATFORM_PACKAGE_LABEL size:"` to extract
the size. When grep matches two lines, the resulting variables contain newlines,
corrupting CSV output.

**Fix:** Change the first (informational) occurrence to use a different prefix so
only the final occurrence is parseable. Use `"Package size:"` for the informational
line (not matched by the `$PLATFORM_PACKAGE_LABEL size:` grep pattern since
`PLATFORM_PACKAGE_LABEL` is `"APP"` for all Apple platforms).

3. **`osx/measure_osx_startup.sh` line 205** — Change:
   ```bash
   echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
   ```
   To:
   ```bash
   echo "Package size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
   ```

4. **`maccatalyst/measure_maccatalyst_startup.sh` line 206** — Same change:
   ```bash
   echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
   ```
   To:
   ```bash
   echo "Package size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
   ```

5. **`ios/measure_simulator_startup.sh` line 338** — Same change:
   ```bash
   echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
   ```
   To:
   ```bash
   echo "Package size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
   ```

**Leave untouched:** The second `"APP size:"` echo in each script (osx line 382,
maccatalyst line 384, ios line 476) — these are the parseable lines that
`measure_all.sh` relies on.

---

## Acceptance Criteria

1. **obj/ cleanup:**
   - `grep -n 'rm -rf' osx/measure_osx_startup.sh` shows `obj` is cleaned alongside `bin`
   - `grep -n 'rm -rf' maccatalyst/measure_maccatalyst_startup.sh` shows same
   - Pattern matches `measure_startup.sh` line 201 and `ios/measure_simulator_startup.sh` line 289

2. **Duplicate APP size fix:**
   - `grep -c "APP size:" osx/measure_osx_startup.sh` returns `1` (was `2`)
   - `grep -c "APP size:" maccatalyst/measure_maccatalyst_startup.sh` returns `1` (was `2`)
   - `grep -c "APP size:" ios/measure_simulator_startup.sh` returns `1` (was `2`)
   - `grep -c "Package size:" <each script>` returns `1`
   - Running any script and piping output through `grep "APP size:"` matches exactly one line

3. **No behavioral regression:**
   - Scripts still output `"Generic Startup | avg | min | max"` line (unchanged)
   - Scripts still output `"APP size: X MB (Y bytes)"` line at the end (unchanged)
   - `measure_all.sh` parsing logic (lines 159-164) works correctly without modification

---

## Dependencies

None — this is the first step. No dependency on other plans.

---

## Risks

- **Very low risk.** Both changes are mechanical and don't affect measurement logic.
- The `"Package size:"` prefix for the informational line is purely cosmetic — it's
  not parsed by any other script.
- The `obj/` cleanup is additive — it only removes files that were previously left
  behind.
