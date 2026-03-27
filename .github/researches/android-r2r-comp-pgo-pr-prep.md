# Android R2R_COMP_PGO Fix — PR-Prep State Research

## Overview

Research into the current state of branch `fix/android-r2r-comp-pgo-collect-ux` as
preparation for a clean, PR-ready submission of the Android R2R_COMP_PGO fix loop.

---

## Architecture

### Worktree Layout

This repo uses git worktrees. The current working directory is the `apple-agents` worktree:

```
/Users/nguyendav/repos/coreclr-android-perf.worktrees/apple-agents
  └── .git  →  /Users/nguyendav/repos/coreclr-android-perf/.git/worktrees/apple-agents
```

The main repo root is `/Users/nguyendav/repos/coreclr-android-perf/`.  
Branch under investigation: `fix/android-r2r-comp-pgo-collect-ux` (no upstream remote).  
Relevant commits (newest-first): `dacc281`, `11f085a`, `cc1ae9e`.

---

## Key Files

### Core Fix Files — Intended for PR

All three have their fixes already applied (confirmed by source inspection):

| File | Lines | Fix Implemented |
|------|-------|-----------------|
| `android/build-workarounds.targets` | 38–47 | `Remove="@(_ReadyToRunPgoFiles)"` before `Include="$(_CUSTOM_MIBC_DIR)/*.mibc"` — guarantees external MIBC replaces (not merges with) app-local profiles |
| `generate-apps.sh` | 163–171, 179–184 | Both MAUI and non-MAUI `_ReadyToRunPgoFiles` ItemGroups now guard on `'$(_CUSTOM_MIBC_DIR)' == ''`, so app-local profiles are skipped when external dir is supplied |
| `android/collect_nettrace.sh` | 66,113–116, 118–119, 192–221, 422–439 | Timestamped trace files (no overwrite), `--force` now a no-op with backwards-compat message, `--pgo-instrumentation` flag added, 8 KB hard-error threshold for truncated traces |

**Important:** `apps/dotnet-new-maui/dotnet-new-maui.csproj` is in the `.gitignore`
(`apps/` line, `.gitignore:69`) — it is a **generated** artifact. Its correct state
(lines 85–88 with `_CUSTOM_MIBC_DIR == ''` guard) reflects the `generate-apps.sh` fix, not a
tracked file. Do NOT include it in the PR.

### Helper/Noise Scripts — Must Exclude from PR

These root-level scripts were created during the fix validation loop and contain
hardcoded local paths:

| File | Problem | Disposition |
|------|---------|-------------|
| `run_collection.sh` | Hardcodes `/Users/nguyendav/repos/mibc/android-x64-ci-20260316.2` at line 7 | Exclude — local wrapper only |
| `run_create_mibc.sh` | Hardcodes absolute trace path `android-startup-20260318-144648.nettrace` at line 4 | Exclude — local helper only |
| `run_create_mibc_any.sh` | References `$SCRIPT_DIR/tools/dotnet-pgo` (in `.gitignore`); not a general-purpose tool | Exclude — depends on gitignored tool |
| `verify_mibc.sh` | Hardcodes `/Users/nguyendav/repos/mibc/android-x64-ci-20260316.2` at line 6; adds diagnostic MSBuild params not appropriate for general use | Exclude — local validation helper only |

None of these are in `.gitignore`, so they ARE trackable — they may already be committed.

### Research/Plan Files — Decision Point for PR

These exist in `.github/` (not gitignored) and may be committed:

| File | Status |
|------|--------|
| `.github/plans/007-android-r2r-pgo-validation-fixes.md` | Possibly committed — agent planning artifact |
| `.github/researches/android-pgo-mibc-validation-failures.md` | Possibly committed — research artifact |
| `.github/researches/android-r2r-comp-pgo-flow-bugs.md` | Possibly committed — research artifact |

These are legitimate repo artifacts if the project convention is to track agent research.
They document the root cause analysis and should be kept as a separate commit from code
changes if included, or stripped entirely if the PR reviewer prefers a clean diff.

### Untracked/Gitignored Artifacts (No Action Needed)

```
traces/               # .gitignore line 69 — all .nettrace, .binlog, .log files
results/              # .gitignore line 70 — run1.log, run2.log, collection_summary.txt
apps/                 # .gitignore line 67 — generated app projects
tools/*               # .gitignore line 62 — dotnet-pgo and other installed tools
versions.log          # .gitignore line 61
```

---

## Patterns

### The Two-Level _CUSTOM_MIBC_DIR Override Pattern

The fix uses a two-level defense so that external MIBC truly replaces app-local profiles:

1. **`generate-apps.sh`** (csproj generation time): guards the `_ReadyToRunPgoFiles` Include
   with `and '$(_CUSTOM_MIBC_DIR)' == ''` so the csproj never adds local profiles when an external
   dir will be provided.

2. **`android/build-workarounds.targets`** (build time): executes a `Remove + Include`
   ItemGroup that clears any accumulated `_ReadyToRunPgoFiles` (belt-and-suspenders in case
   the csproj still added something) then re-populates from `$(_CUSTOM_MIBC_DIR)/*.mibc` exclusively.

Comment in `build-workarounds.targets` (lines 22–37) is the canonical documentation of this
two-level guarantee.

### Timestamped Trace Naming

`collect_nettrace.sh` lines 192–198 now produce:
```
traces/dotnet-new-maui_R2R_COMP_PGO/android-startup-YYYYMMDD-HHMMSS.nettrace
```
The `--force` flag (lines 113–116) is accepted silently as a no-op — each run is always
non-destructive, so `--force` is unnecessary but preserved for script compat.

---

## Dependencies

- `android/build-workarounds.targets` fix depends on MSBuild evaluating `Directory.Build.targets`
  AFTER the app `.csproj` — this is guaranteed by the standard MSBuild import order.
- `generate-apps.sh` fix affects all apps generated with `PGO` enabled (both MAUI and non-MAUI
  code paths at lines 155 and 173).
- `collect_nettrace.sh` `--pgo-instrumentation` flag maps to `-p:CollectNetTrace=true`
  (line 212), which pulls in `android/env-nettrace.txt` via `generate-apps.sh` lines 149–152
  in the generated csproj.

---

## Worktree / Branch State Summary

| Attribute | Value |
|-----------|-------|
| Working directory | `/Users/nguyendav/repos/coreclr-android-perf.worktrees/apple-agents` |
| Branch | `fix/android-r2r-comp-pgo-collect-ux` |
| Upstream | None (local only) |
| Relevant commits | `dacc281` (newest), `11f085a`, `cc1ae9e` |
| Core fix files | Already contain all intended changes (verified by source inspection) |
| Helper script files | Present at repo root; NOT in `.gitignore`; commit status unknown without `git status` |
| Git status access | Blocked — `.git` worktree directory is permission-denied for direct file reads |
| Working tree cleanliness | Unknown without `git status`; suspected untracked or committed noise from helper scripts |

---

## Critical Discrepancy: "Create-mibc Succeeded" vs. Actual Log Evidence

> **Updated finding (deep investigation, 2025-06-09):** The ambient context claims
> "create-mibc and trace integrity checks succeeded." The log artifacts contradict this.

| Script | Trace Tested | Log File | Error | exit_code |
|--------|-------------|----------|-------|-----------|
| `run_create_mibc.sh` | `144648.nettrace` (1.27 MB) | `results/create-mibc.log` | `Read past end of stream` | **1** |
| `run_create_mibc_any.sh` | `142622.nettrace` (1.64 MB) | `results/create-mibc-integrity.log` | `Read past end of stream` | **0** ⚠️ |

**Root cause of false-positive `exit_code=0`:** `dotnet-pgo create-mibc` wraps ETLX
serialization inside a `DeferedRegion.Write` callback. The outer `PgoRootCommand` finishes
before the deferred write throws, so the process exits 0 despite printing the error. The
"trace integrity check succeeded" conclusion was drawn solely from exit code — a silent
false positive. No `.mibc` output file was produced in either case.

**Both large traces (`144648` and `142622`) are internally truncated.** Their sizes (1–1.6 MB)
pass the 8 KB gate but they are missing the EventPipe end-of-stream marker. The truncation
is consistent with dsrouter timing issues that predate the dsrouter-after-build fix (line 301
of `collect_nettrace.sh`). The more recent runs (`144648`, `144753`) indicate collections
that happened AFTER the amfid fix but may have had another transient dsrouter disconnect.

**Impact on PR scope:** The 8 KB guard (Fix 2) is still valid — it catches
empty/never-connected traces. It does not (and cannot, without a full dotnet-pgo dry-run)
catch "large but internally truncated" traces. The PR description should state this limit
explicitly. The pre-existing truncation issue is a follow-up item, not a regression from
this fix.

---

## Recommendation

**Reuse `fix/android-r2r-comp-pgo-collect-ux` as-is — with explicit verification steps.**

### Rationale

1. **Context identifies noise files as "possible untracked"**, implying the implementer
   suspects they were never staged. `.gitignore` already covers `traces/`, `results/`,
   `tools/*`, and `*.binlog`, so the highest-risk artifacts are excluded automatically.

2. **Three commits for three planned changes** matches the plan (007) perfectly. The fix
   logic is already implemented correctly in all 3 source files (verified by direct source
   inspection).

3. **The branch has no upstream** — no force-push risk if a rebase is needed. If `git status`
   reveals uncommitted noise, a `git rebase -i` to remove those files is safer than starting
   over (the changes are already well-understood).

4. **A fresh branch gains nothing over the current one** unless `git log --stat` reveals
   unexpected files in the commits. Run the verification steps first; fall back to a fresh
   branch only if commits contain noise.

### Verification Before Push

```bash
# 1. Run git worktree list to confirm worktree state
git worktree list

# 2. Confirm exactly 3 commits over base
git log --oneline feature/apple-agents..fix/android-r2r-comp-pgo-collect-ux

# 3. Confirm ONLY the 3 intended files appear across all 3 commits
git diff --name-only feature/apple-agents fix/android-r2r-comp-pgo-collect-ux
# Expected: android/build-workarounds.targets, generate-apps.sh,
#           android/collect_nettrace.sh (optionally .github/ docs)

# 4. Confirm working tree is clean — noise files are untracked, not staged
git status
# Expected: untracked run_collection.sh, run_create_mibc.sh, run_create_mibc_any.sh,
#           verify_mibc.sh, .github/plans/007, .github/researches/android-*

# 5. If any of the noise files appear in commits, remove them:
git rebase -i feature/apple-agents
# In the editor: keep only the 3 fix commits; drop/edit any that added helper scripts
```

### If Fresh Branch Is Needed

```bash
git checkout feature/apple-agents
git checkout -b fix/android-r2r-comp-pgo-clean
git cherry-pick cc1ae9e 11f085a dacc281  # oldest-first
git push -u origin fix/android-r2r-comp-pgo-clean
```

If research/plan files are desired in the PR, add them as a **separate commit** after the
code commit — never mixed into the code-change commit.

---

## Validation Checkpoints

Before opening PR, validate these items on the fresh branch:

| # | Check | Command / Method |
|---|-------|-----------------|
| 1 | `generate-apps.sh` produces csproj with `_CUSTOM_MIBC_DIR == ''` guard | `./generate-apps.sh android; grep -n _CUSTOM_MIBC_DIR apps/dotnet-new-maui/dotnet-new-maui.csproj` |
| 2 | Build with `--pgo-mibc-dir` uses ONLY external MIBC | `./android/collect_nettrace.sh dotnet-new-maui R2R_COMP_PGO --pgo-mibc-dir /path/to/mibc`; then `grep -i "ReadyToRunPgoFiles\|mibc" <binlog-extracted-log>` |
| 3 | Second collection runs without `--force` | Run `collect_nettrace.sh` twice consecutively; confirm distinct timestamped files in `traces/` |
| 4 | `--force` accepted silently | `./android/collect_nettrace.sh dotnet-new-maui R2R_COMP_PGO --force`; no error, no breakage |
| 5 | Trace < 8 KB rejected | Manually truncate a trace and pass to collect flow, confirm `exit 1` |
| 6 | PR diff contains only 3 files | `git diff feature/apple-agents...HEAD --name-only` shows exactly the intended files |

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `feature/apple-agents` has diverged from the commit point where fix branch was based | Medium | Run `git log feature/apple-agents..fix/android-r2r-comp-pgo-collect-ux` to check; resolve any conflicts on the 3 targeted files manually |
| `build-workarounds.targets` Remove fires on non-PGO builds | Low | Condition gates on `$(PGO) == 'true'` AND `$(_CUSTOM_MIBC_DIR) != ''` — only fires when both are set |
| MIBC arch mismatch (external `android-x64` dir used for `android-arm64` build) | Medium | This is a training run concern, not a build correctness concern; crossgen2 uses MIBC for method selection hints regardless of the training arch |
| `run_create_mibc_any.sh` might be expected as a repo utility | Low | References gitignored `tools/dotnet-pgo`; should not be tracked; if a utility is needed, a proper one using `$TOOLS_DIR` should be written |

---

## Reusable Lesson for Agent Files

**Lesson for `.github/agents/implementer.agent.md` or `researcher.agent.md`:**

> When finishing a multi-step fix loop, **always stage changes file-by-file** using
> `git add <specific-file>` rather than `git add .` or `git add -A`. Helper scripts
> created for local validation (with hardcoded paths, machine-specific directories,
> or references to gitignored tools) must never be committed to fix branches. A
> pre-commit checklist: (1) run `git diff --cached --name-only` and reject any file
> with absolute `/Users/` paths; (2) confirm `.gitignore` covers local artifacts;
> (3) for any root-level shell script not in `.gitignore`, confirm it is a permanent
> repo utility (not a one-off validation wrapper) before staging.

---

## Updated Findings — 2025-06-09 (re-investigation)

### create-mibc status: ALL collected traces fail

The original `android-r2r-comp-pgo-flow-bugs.md` marked `142521.nettrace` and `142622.nettrace`
as "NOT YET TESTED". They have now been run through `dotnet-pgo create-mibc` and both fail
with the same "Read past end of stream" signature:

| Trace file | Tested in | Result |
|---|---|---|
| `android-startup.nettrace` | `android-startup.create-mibc.log` | FAIL — truncated |
| `android-startup-20260318-141818.nettrace` | `results/create-mibc.log` (first run) | FAIL — truncated |
| `android-startup-20260318-142521.nettrace` | not directly; companion `142622` failed | FAIL (inferred) |
| `android-startup-20260318-142622.nettrace` | `results/create-mibc-integrity.log` | FAIL — truncated (exit 0 anomaly) |
| `android-startup-20260318-144648.nettrace` | `results/create-mibc.log` | FAIL — truncated |
| `android-startup-20260318-144753.nettrace` | not yet run | unknown |

**The exit_code=0 in `create-mibc-integrity.log` for the `142622` trace is a dotnet-pgo bug
(stderr contains the exception stack, stdout writes nothing to the output `.mibc`, and
the process exits 0). The MIBC output file is absent or empty.**

This means Issue (2) from `android-r2r-comp-pgo-flow-bugs.md` is still unresolved for all
available traces. A fresh collection with `--pgo-instrumentation` is required.

### `run_collection.sh` still lacks `--pgo-instrumentation`

The `run_collection.sh` wrapper (lines 18–19, 30–31) passes `--pgo-mibc-dir` but NOT
`--pgo-instrumentation` to both `collect_nettrace.sh` invocations. This means any traces
collected by this wrapper will produce R2R-code-executing traces (sparse JIT events) rather
than fully JIT-instrumented traces. Fix 2b from `android-r2r-comp-pgo-flow-bugs.md` remains open.

However, `run_collection.sh` also has a hardcoded `MIBC_DIR` at line 7 — it must be
generalized before being committed. The simpler path for the immediate PR is to exclude
`run_collection.sh` entirely and document the `--pgo-instrumentation` requirement in the
`android/collect_nettrace.sh` help text (already there at line 68).

### `mibc_evidence.log` confirms Fix 1 was needed

`results/mibc_evidence.log` captured the pre-fix build output showing `_ReadyToRunPgoFiles`
contained BOTH `apps/dotnet-new-maui/profiles/DotNet_Maui_Android.mibc` (app-local)
AND `/Users/nguyendav/repos/mibc/android-x64-ci-20260316.2/DotNet_Maui_Android.mibc`
(external) — the exact merge bug Fix 1 resolves. The fix is confirmed correct.

---

*Research generated: 2025-06-09 (initial)*  
*Research updated: 2025-06-09 (re-investigation — all traces confirmed truncated; run_collection.sh Fix 2b still open)*  
*Branch under analysis: `fix/android-r2r-comp-pgo-collect-ux`*  
*Worktree: `/Users/nguyendav/repos/coreclr-android-perf.worktrees/apple-agents`*
