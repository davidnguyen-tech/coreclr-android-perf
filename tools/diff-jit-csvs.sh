#!/bin/bash
# =============================================================================
# tools/diff-jit-csvs.sh — Diff two PerfView JIT stats CSV files
#
# Compares two PerfView JIT stats CSVs (exported from PerfView's JIT Stats
# view) and produces three output files:
#   - pgo-only-methods.csv:      methods JIT'd only in the comparison build
#   - baseline-only-methods.csv:  methods JIT'd only in the baseline build
#   - common-methods.csv:         methods JIT'd in both builds
#
# Usage:
#   ./tools/diff-jit-csvs.sh <baseline.csv> <comparison.csv>
#
# Output files are written to the same directory as the comparison CSV.
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# usage — print help text
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage:
  diff-jit-csvs.sh <baseline.csv> <comparison.csv>

Arguments:
  <baseline.csv>     Baseline PerfView JIT stats CSV (e.g. R2R_COMP build)
  <comparison.csv>   Comparison PerfView JIT stats CSV (e.g. R2R_COMP_PGO build)

Output:
  Three CSV files are written to the same directory as <comparison.csv>:
    pgo-only-methods.csv      — methods only in comparison (PGO regressed / not precompiled)
    baseline-only-methods.csv — methods only in baseline (PGO improved / now precompiled)
    common-methods.csv        — methods in both, with JIT time from each build

EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [ $# -ne 2 ]; then
    echo "Error: expected 2 arguments, got $#" >&2
    usage
fi

BASELINE_CSV="$1"
COMPARISON_CSV="$2"

if [ ! -f "$BASELINE_CSV" ]; then
    echo "Error: baseline CSV not found: $BASELINE_CSV" >&2
    exit 1
fi

if [ ! -r "$BASELINE_CSV" ]; then
    echo "Error: baseline CSV not readable: $BASELINE_CSV" >&2
    exit 1
fi

if [ ! -f "$COMPARISON_CSV" ]; then
    echo "Error: comparison CSV not found: $COMPARISON_CSV" >&2
    exit 1
fi

if [ ! -r "$COMPARISON_CSV" ]; then
    echo "Error: comparison CSV not readable: $COMPARISON_CSV" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine output directory (same as comparison CSV)
# ---------------------------------------------------------------------------
OUTPUT_DIR="$(cd "$(dirname "$COMPARISON_CSV")" && pwd)"

# ---------------------------------------------------------------------------
# Run the diff via inline Python
# ---------------------------------------------------------------------------
python3 - "$BASELINE_CSV" "$COMPARISON_CSV" "$OUTPUT_DIR" <<'PYTHON_SCRIPT'
import csv
import os
import sys

def parse_jit_csv(filepath):
    """Parse a PerfView JIT stats CSV file.

    Returns (headers, rows_by_method) where rows_by_method maps
    MethodName -> row dict. If a method appears multiple times (re-JIT),
    we keep the row with the largest JitTime MSec so the diff reflects
    the worst case.
    """
    rows_by_method = {}
    headers = None

    with open(filepath, newline='', encoding='utf-8-sig') as f:
        reader = csv.reader(f)
        for row in reader:
            # Skip empty rows
            if not row or all(cell.strip() == '' for cell in row):
                continue

            # First non-empty row is the header
            if headers is None:
                headers = [h.strip() for h in row]
                if 'MethodName' not in headers:
                    print(f"Error: 'MethodName' column not found in {filepath}", file=sys.stderr)
                    print(f"  Found columns: {headers}", file=sys.stderr)
                    sys.exit(1)
                if 'JitTime MSec' not in headers:
                    print(f"Error: 'JitTime MSec' column not found in {filepath}", file=sys.stderr)
                    print(f"  Found columns: {headers}", file=sys.stderr)
                    sys.exit(1)
                continue

            # Validate column count
            if len(row) != len(headers):
                # PerfView sometimes has trailing commas; pad or truncate
                if len(row) < len(headers):
                    row.extend([''] * (len(headers) - len(row)))
                else:
                    row = row[:len(headers)]

            record = {headers[i]: row[i].strip() for i in range(len(headers))}
            method_name = record['MethodName']
            jit_time = float(record['JitTime MSec'])

            # Keep the entry with the largest JIT time for duplicate methods
            if method_name in rows_by_method:
                existing_time = float(rows_by_method[method_name]['JitTime MSec'])
                if jit_time > existing_time:
                    rows_by_method[method_name] = record
            else:
                rows_by_method[method_name] = record

    if headers is None:
        print(f"Error: no data found in {filepath}", file=sys.stderr)
        sys.exit(1)

    return headers, rows_by_method


def write_csv(filepath, headers, rows):
    """Write rows (list of dicts) to a CSV file."""
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(rows)


def main():
    baseline_path = sys.argv[1]
    comparison_path = sys.argv[2]
    output_dir = sys.argv[3]

    # Parse both CSVs
    baseline_headers, baseline_methods = parse_jit_csv(baseline_path)
    comparison_headers, comparison_methods = parse_jit_csv(comparison_path)

    baseline_names = set(baseline_methods.keys())
    comparison_names = set(comparison_methods.keys())

    # Compute the three sets
    comparison_only_names = comparison_names - baseline_names
    baseline_only_names = baseline_names - comparison_names
    common_names = baseline_names & comparison_names

    # --- 1. pgo-only-methods.csv (comparison-only, sorted by JIT time desc) ---
    comparison_only_rows = [comparison_methods[n] for n in comparison_only_names]
    comparison_only_rows.sort(key=lambda r: float(r['JitTime MSec']), reverse=True)

    pgo_only_path = os.path.join(output_dir, 'pgo-only-methods.csv')
    write_csv(pgo_only_path, comparison_headers, comparison_only_rows)

    # --- 2. baseline-only-methods.csv (baseline-only, sorted by JIT time desc) ---
    baseline_only_rows = [baseline_methods[n] for n in baseline_only_names]
    baseline_only_rows.sort(key=lambda r: float(r['JitTime MSec']), reverse=True)

    baseline_only_path = os.path.join(output_dir, 'baseline-only-methods.csv')
    write_csv(baseline_only_path, baseline_headers, baseline_only_rows)

    # --- 3. common-methods.csv (both, with columns from each side) ---
    # Prefix baseline columns with "baseline_" and comparison columns with "comparison_"
    # except MethodName which appears once
    common_headers = ['MethodName']
    for h in baseline_headers:
        if h != 'MethodName':
            common_headers.append(f'baseline_{h}')
    for h in comparison_headers:
        if h != 'MethodName':
            common_headers.append(f'comparison_{h}')
    # Add a delta column for JIT time
    common_headers.append('JitTime Delta MSec')

    common_rows = []
    for name in common_names:
        br = baseline_methods[name]
        cr = comparison_methods[name]
        merged = {'MethodName': name}
        for h in baseline_headers:
            if h != 'MethodName':
                merged[f'baseline_{h}'] = br[h]
        for h in comparison_headers:
            if h != 'MethodName':
                merged[f'comparison_{h}'] = cr[h]
        baseline_jit = float(br['JitTime MSec'])
        comparison_jit = float(cr['JitTime MSec'])
        merged['JitTime Delta MSec'] = f'{comparison_jit - baseline_jit:.3f}'
        common_rows.append(merged)

    common_rows.sort(key=lambda r: float(r['comparison_JitTime MSec']), reverse=True)

    common_path = os.path.join(output_dir, 'common-methods.csv')
    write_csv(common_path, common_headers, common_rows)

    # --- Summary ---
    baseline_total_jit = sum(float(r['JitTime MSec']) for r in baseline_methods.values())
    comparison_total_jit = sum(float(r['JitTime MSec']) for r in comparison_methods.values())

    comp_only_jit = sum(float(r['JitTime MSec']) for r in comparison_only_rows)
    base_only_jit = sum(float(r['JitTime MSec']) for r in baseline_only_rows)
    common_base_jit = sum(float(baseline_methods[n]['JitTime MSec']) for n in common_names)
    common_comp_jit = sum(float(comparison_methods[n]['JitTime MSec']) for n in common_names)

    print(f"=== JIT CSV Diff Summary ===")
    print()
    print(f"Baseline:   {os.path.basename(baseline_path)}")
    print(f"  Methods:  {len(baseline_methods):,}")
    print(f"  JIT time: {baseline_total_jit:,.1f} ms")
    print()
    print(f"Comparison: {os.path.basename(comparison_path)}")
    print(f"  Methods:  {len(comparison_methods):,}")
    print(f"  JIT time: {comparison_total_jit:,.1f} ms")
    print()
    print(f"--- Diff ---")
    print(f"Comparison-only (pgo-only-methods.csv):  {len(comparison_only_rows):,} methods, {comp_only_jit:,.1f} ms JIT time")
    print(f"Baseline-only (baseline-only-methods.csv): {len(baseline_only_rows):,} methods, {base_only_jit:,.1f} ms JIT time")
    print(f"Common (common-methods.csv):             {len(common_rows):,} methods")
    print(f"  Baseline JIT time: {common_base_jit:,.1f} ms")
    print(f"  Comparison JIT time: {common_comp_jit:,.1f} ms")
    print(f"  Delta: {common_comp_jit - common_base_jit:+,.1f} ms")
    print()
    print(f"Output directory: {output_dir}")


if __name__ == '__main__':
    main()
PYTHON_SCRIPT
