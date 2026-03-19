# Android R2R_COMP_PGO Fix — PR Prep Plan

**Plan file**: `.github/plans/008-android-r2r-comp-pgo-pr-prep.md`  
**Scope**: Produce a clean, PR-ready local branch containing exactly the three verified fix commits for the Android R2R_COMP_PGO bug — no noise, no untracked artifacts, no push.  
**Status**: Active  
**Do NOT push or open a PR** until explicit approval is given.

---

## Overview

The fix spans three commits (`dacc281`, `11f085a`, `cc1ae9e`) on branch
`fix/android-r2r-comp-pgo-collect-ux`. Those commits touch exactly six product
files. The current worktree also carries unrelated noise (helper scripts,
plan files, local artifacts, submodule untracked content) that must be kept
out of the PR.

Cleanest isolation strategy: **create a fresh branch from `feature/apple-agents`
and cherry-pick the three commits in order**. This is preferred over scrubbing
the existing branch because cherry-pick produces an auditable, replay-clean
history with no residual working-tree clutter.

### Intended PR file set (exactly six files)

| # | File | Change summary |
|---|------|---------------|
| 1 | `.github/agents/implementer.agent.md` | Agent guidance update |
| 2 | `android/build-workarounds.targets` | Remove-then-include external MIBC; replaces app-local profiles |
| 3 | `android/collect_nettrace.sh` | Hard-error on trace < 8 KB; `--pgo-mibc-dir` collection path |
| 4 | `build.sh` | `--pgo-mibc-dir` flag plumbed to MSBuild `-p:PgoMibcDir=` |
| 5 | `generate-apps.sh` | `PgoMibcDir == ''` guard on app-local profile ItemGroups (×2) |
| 6 | `measure_startup.sh` | `--pgo-mibc-dir` forwarded to `build.sh` invocation |

### Noise explicitly excluded

- `plan.md` (root-level scratch file)
- `.github/plans/007-android-r2r-pgo-validation-fixes.md` (superseded by this plan)
- `run_collection.sh`, `run_create_mibc.sh`, `run_create_mibc_any.sh`, `verify_mibc.sh`
- `results/`, `traces/`, `build/` local artifact directories
- Any untracked research files not in the product commit set
- `external/performance` submodule untracked content (must not appear in diff)

---

## Tasks (ordered)

### STEP 1 — Decision gate: verify cherry-pick is safe

**Goal**: Confirm `feature/apple-agents` exists locally and the three SHAs are
reachable from the current worktree before creating anything.

**Actions**:
1. `git branch -a | grep feature/apple-agents` — confirm base branch exists.
2. `git log --oneline dacc281 11f085a cc1ae9e` — confirm all three SHAs are
   reachable (each should print exactly one line).
3. `git show --stat dacc281 11f085a cc1ae9e` — confirm each touches only files
   in the intended PR file set and nothing else.
4. If any SHA is missing or touches unexpected files, **stop and report** before
   proceeding. Do not attempt to reconstruct commits manually.

**Acceptance**: All three SHAs resolve and their `--stat` output references only
the six files listed in the table above.

---

### STEP 2 — Create the clean PR branch

**Goal**: Establish an isolated branch rooted on `feature/apple-agents` in this
worktree.

**Actions**:
1. From the worktree root:
   ```
   git checkout feature/apple-agents
   git checkout -b fix/android-r2r-comp-pgo
   ```
   Branch name convention: `fix/<short-description>` targeting `feature/apple-agents`.
2. Verify `git status` is clean and `git log --oneline -1` shows the tip of
   `feature/apple-agents`.

**Acceptance**: New branch exists, HEAD is `feature/apple-agents` tip, working
tree is clean.

**Risk**: If `feature/apple-agents` has uncommitted changes, stash or abort
before switching. Never carry noise into the new branch.

---

### STEP 3 — Cherry-pick the three commits in order

**Goal**: Replay only the three fix commits onto the clean branch.

**Actions**:
1. Cherry-pick in chronological order (oldest first):
   ```
   git cherry-pick dacc281
   git cherry-pick 11f085a
   git cherry-pick cc1ae9e
   ```
2. After each cherry-pick, run `git show --stat HEAD` to confirm the commit
   touched only expected files.
3. If a conflict arises, **do not auto-resolve** — stop and report. Conflicts
   here signal that `feature/apple-agents` diverged from the original base in a
   way that needs manual review.

**Acceptance**: Three commits applied, `git log --oneline feature/apple-agents..HEAD`
shows exactly three lines, no merge commits.

---

### STEP 4 — Verify the diff is clean (no noise)

**Goal**: Confirm the PR diff contains exactly the six intended files and nothing
else.

**Actions**:
1. `git diff --name-only feature/apple-agents...HEAD` — output must be exactly:
   ```
   .github/agents/implementer.agent.md
   android/build-workarounds.targets
   android/collect_nettrace.sh
   build.sh
   generate-apps.sh
   measure_startup.sh
   ```
   Any additional file is a blocker; investigate and remove before proceeding.
2. `git status` — working tree must be clean (no untracked files in the diff).
3. `git submodule status` — confirm `external/performance` shows no `+` or `-`
   prefix changes relative to the base (no submodule pointer drift in the PR).

**Acceptance**: Diff is exactly six files; submodule pointer is unchanged vs
`feature/apple-agents` tip.

---

### STEP 5 — Static content review: `android/build-workarounds.targets`

**Goal**: Confirm the MSBuild change correctly removes app-local items before
adding external ones, and is scoped to android+R2R+Composite+PGO.

**Checklist**:
- [ ] `<_ReadyToRunPgoFiles Remove="@(_ReadyToRunPgoFiles)" />` appears **before**
      the `Include` line (order matters in MSBuild ItemGroups).
- [ ] Condition guards: `TargetPlatformIdentifier == android`, `PublishReadyToRun == true`,
      `PublishReadyToRunComposite == true`, `PGO == true`, `PgoMibcDir != ''`.
- [ ] `Include` glob is `$(PgoMibcDir)/*.mibc` (single star, not globstar — matches
      flat directory; document if subdirectories are intentionally excluded).
- [ ] No property group or target was inadvertently removed by the cherry-pick.
- [ ] The block sits inside `<Project>` and has correct XML structure (no unclosed tags).

**Acceptance**: All checklist items pass. No structural XML regressions.

---

### STEP 6 — Static content review: `generate-apps.sh`

**Goal**: Confirm both ItemGroup conditions (MAUI and non-MAUI) correctly guard
on `PgoMibcDir == ''` so app-local profiles are suppressed when external MIBC
is supplied.

**Checklist**:
- [ ] MAUI block condition includes `and '$(PgoMibcDir)' == ''`.
- [ ] Non-MAUI block condition includes `and '$(PgoMibcDir)' == ''`.
- [ ] Comment in each block references `build-workarounds.targets` as the
      companion file that handles the external MIBC injection (cross-reference
      comment keeps the two files coherent).
- [ ] No other ItemGroup for `_ReadyToRunPgoFiles` was introduced without the
      same guard.

**Acceptance**: Both guards are present and the generated `.csproj` XML would
produce no app-local profile items when `PgoMibcDir` is non-empty.

---

### STEP 7 — Static content review: `android/collect_nettrace.sh`

**Goal**: Confirm the trace size validation is a hard error (not a warning) at
the correct threshold, and `--pgo-mibc-dir` collection path is correctly wired.

**Checklist**:
- [ ] `TRACE_SIZE -lt 8192` threshold is present and exits with code 1 on failure.
- [ ] Error message is actionable (lists `adb devices`, port check, `adb reverse`).
- [ ] `--pgo-mibc-dir` flag accepted by the script and forwarded correctly to
      downstream invocations (if applicable in collection flow).
- [ ] No regression to the existing collection path (script should still work
      without `--pgo-mibc-dir`).
- [ ] `wc -c` + `tr -d ' '` pattern is portable (works on both macOS and Linux).

**Acceptance**: All checklist items pass.

---

### STEP 8 — Static content review: `build.sh` and `measure_startup.sh`

**Goal**: Confirm flag plumbing is correct end-to-end.

**Checklist for `build.sh`**:
- [ ] `--pgo-mibc-dir <path>` accepted at position `$5`/`$6` and validated
      (directory must exist).
- [ ] Translates to `-p:PgoMibcDir=<path>` in `$MSBUILD_ARGS`.
- [ ] Regression: script still works for `R2R_COMP` (no `--pgo-mibc-dir`) and
      other configs without the new flag.
- [ ] Usage string updated to document `--pgo-mibc-dir`.

**Checklist for `measure_startup.sh`**:
- [ ] `--pgo-mibc-dir` parsed and stored in `PGO_MIBC_DIR`.
- [ ] When non-empty, forwarded to `build.sh` (or equivalent build invocation).
- [ ] Usage/help string mentions `--pgo-mibc-dir`.
- [ ] Does not break runs without the flag.

**Acceptance**: All checklist items pass.

---

### STEP 9 — Static content review: `.github/agents/implementer.agent.md`

**Goal**: Confirm agent guidance update is coherent and does not conflict with
planner conventions.

**Checklist**:
- [ ] Change is purely documentary (no functional code).
- [ ] No sensitive data, credentials, or personal information was introduced.
- [ ] Diff is small and scoped to the intended guidance update.

**Acceptance**: Checklist passes; no blockers.

---

### STEP 10 — Functional validation: `build.sh` R2R_COMP_PGO path

**Goal**: Verify the build completes with an external MIBC dir and crossgen2
receives only external profiles.

**Preconditions**: A prepared `apps/` directory and `--dotnet` SDK available.
Skip this step if a full build environment is not available locally; document
as "deferred to CI".

**Validation sequence**:
```bash
# Prepare a test external MIBC dir (copy or symlink existing profiles/)
EXTERNAL_MIBC=$(mktemp -d)
cp profiles/*.mibc "$EXTERNAL_MIBC/" 2>/dev/null || true
# At least one *.mibc must exist; create a placeholder if needed

./build.sh dotnet-new-maui R2R_COMP_PGO build 1 --pgo-mibc-dir "$EXTERNAL_MIBC"
```

**What to inspect**:
- MSBuild binlog (`.binlog` in `apps/dotnet-new-maui/`): open with `dotnet
  binlog` (MSBuild Structured Log Viewer) and search for `_ReadyToRunPgoFiles`.
  All items should resolve to `$EXTERNAL_MIBC/*.mibc`; no `profiles/` paths
  should appear.
- Build must succeed (exit 0).

**Regression check** (no `--pgo-mibc-dir`):
```bash
./build.sh dotnet-new-android R2R_COMP build 1
```
Must succeed without error.

**Acceptance**: External MIBC only in binlog; R2R_COMP baseline succeeds.

---

### STEP 11 — Functional validation: `collect_nettrace.sh` trace size gate

**Goal**: Verify the hard error fires on a small trace and is silent on a normal
trace.

**Validation sequence**:
```bash
# Simulate undersized trace
FAKE_TRACE_DIR=$(mktemp -d)
FAKE_TRACE="$FAKE_TRACE_DIR/android-startup-test.nettrace"
dd if=/dev/zero bs=1 count=1000 of="$FAKE_TRACE" 2>/dev/null
TRACE_SIZE=$(wc -c < "$FAKE_TRACE" | tr -d ' ')
# Manually evaluate the threshold logic:
[ "$TRACE_SIZE" -lt 8192 ] && echo "GATE FIRES: correct" || echo "GATE SILENT: incorrect"
```

For the live path, a real device collection is required; if unavailable, the
above manual simulation is sufficient as a dry-run check.

**Acceptance**: Gate fires for < 8 KB trace; normal trace proceeds without error.

---

### STEP 12 — Functional validation: regression for non-PGO Android trace collection

**Goal**: Verify `collect_nettrace.sh` without `--pgo-mibc-dir` still works.

**Actions**:
- Read through `collect_nettrace.sh` and trace the code path for a call without
  `--pgo-mibc-dir` (dry run / static trace).
- Confirm no new code path executes unconditionally that could break the
  existing flow.

**Acceptance**: No unconditional new code in the non-PGO path; existing usage
unchanged.

---

### STEP 13 — Private diff review (self-review checklist)

**Goal**: Final gate before declaring the branch PR-ready.

**Checklist**:
- [ ] `git diff --name-only feature/apple-agents...HEAD` == exactly 6 files
- [ ] `git log --oneline feature/apple-agents..HEAD` == exactly 3 commits
- [ ] No commit has `Co-authored-by:` trailers other than the single allowed
      Copilot trailer
- [ ] No secrets, credentials, PII, or file paths specific to local machine in
      any diff hunk
- [ ] No `plan.md`, helper scripts, or `results/` content in the diff
- [ ] Submodule pointer at `external/performance` unchanged
- [ ] All six files pass their respective static review checklists (Steps 5–9)
- [ ] Commit messages are meaningful and reference the fix intent

**Acceptance**: All items checked. Branch is declared PR-ready locally.

---

### STEP 14 — STOP: do not push or open PR

**This is the final step.** The branch must remain local until explicit approval
is given.

- Do NOT run `git push`.
- Do NOT run `gh pr create`.
- Record the final branch name and HEAD SHA here for handoff:

```
Branch : fix/android-r2r-comp-pgo
Base   : feature/apple-agents
HEAD   : <fill in after Step 3 completes>
Commits: 3 (cherry-picked from dacc281, 11f085a, cc1ae9e)
Files  : 6 (see table in Overview)
Status : LOCAL ONLY — awaiting push approval
```

---

## Dependencies

```
STEP 1 (gate)
  └─► STEP 2 (create branch)
        └─► STEP 3 (cherry-pick)
              └─► STEP 4 (diff verification)
                    ├─► STEP 5  (targets static review)
                    ├─► STEP 6  (generate-apps static review)
                    ├─► STEP 7  (collect_nettrace static review)
                    ├─► STEP 8  (build.sh + measure_startup static review)
                    └─► STEP 9  (agent.md static review)
                          └─► STEP 10 (functional: build R2R_COMP_PGO)
                                └─► STEP 11 (functional: trace size gate)
                                      └─► STEP 12 (functional: regression)
                                            └─► STEP 13 (self-review)
                                                  └─► STEP 14 (STOP)
```

Steps 5–9 are independent of each other and can be done in parallel.
Steps 10–12 each require a full build environment; they may be deferred and
documented as "deferred to CI" without blocking the static review steps.

---

## Testing Strategy

| Test | Requirement | Environment |
|------|------------|-------------|
| Build R2R_COMP_PGO with external MIBC | binlog shows only external *.mibc in `_ReadyToRunPgoFiles` | Local w/ device |
| Build R2R_COMP without `--pgo-mibc-dir` | No regression, build succeeds | Local (no device needed) |
| Trace size gate < 8 KB | Script exits 1 with actionable error | Shell simulation (no device) |
| Trace size gate ≥ 8 KB | Script proceeds normally | Normal collection run |
| `collect_nettrace.sh` without `--pgo-mibc-dir` | Existing flow unchanged | Shell read-through or live run |
| `measure_startup.sh` with `--pgo-mibc-dir` | Flag forwarded to build step | Integration: requires device |

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| `feature/apple-agents` has diverged, cherry-pick conflicts | Medium | Step 1 gate catches this; do not force-resolve — report instead |
| Submodule pointer drift leaks into diff | Low | Step 4 explicitly checks `git submodule status` |
| Extra file from noise commits rides in via cherry-pick | Low | Step 3 `--stat` check per commit catches unexpected files |
| MSBuild ItemGroup ordering: Remove must precede Include | Low | Step 5 checklist explicitly verifies line order |
| `wc -c` portability difference macOS/Linux | Low | Step 7 checklist verifies `tr -d ' '` pattern |
| 8 KB threshold too low for some device/SDK combinations | Low | Documented in Step 11; threshold came from empirical analysis in plan 007 |

---

## Reference

- Research basis: session context provided by user (branch `fix/android-r2r-comp-pgo-collect-ux`, HEAD `cc1ae9e`, commits `dacc281 11f085a cc1ae9e`)
- Prior plan: `.github/plans/007-android-r2r-pgo-validation-fixes.md` (fix design rationale)
- Implementer conventions: `.github/agents/implementer.agent.md`
