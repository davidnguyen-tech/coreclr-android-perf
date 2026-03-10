# 006 — Publish measurement results to secret gists

## Description

After `measure_all.sh` completes, automatically upload `results/summary.csv` and per-app detail CSVs to a secret gist using `gh gist create`. This ensures measurement data is preserved and shareable without polluting the repository.

## Approach

This can be implemented as either:
1. A new `publish-results.sh` script invoked after `measure_all.sh`, or
2. An optional `--publish` flag added directly to `measure_all.sh`

The script should:
- Collect all CSV files from `$RESULTS_DIR`
- Use `gh gist create --public=false` to create a secret gist
- Use a descriptive filename including the platform and date (e.g., `startup-results-maccatalyst-2026-03-10.csv`)
- Print the gist URL to stdout so the user (or orchestrator) can access it

## Acceptance Criteria

- [ ] Running measurements produces a gist URL in the output
- [ ] The gist contains at minimum `summary.csv`
- [ ] Per-app detail CSVs are included when available
- [ ] Gist filenames include platform and date for easy identification
- [ ] No measurement data is committed to the repository
