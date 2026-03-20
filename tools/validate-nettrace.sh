#!/bin/bash
# =============================================================================
# tools/validate-nettrace.sh — Validate .nettrace files
#
# Provides a reusable validate_nettrace() function that checks a .nettrace file
# for structural integrity. Designed to be sourced by collect_nettrace.sh scripts
# or run standalone.
#
# Checks performed:
#   1. File exists and is non-empty
#   2. File is at least 8 KB (minimum viable nettrace)
#   3. First 8 bytes are the ASCII string "Nettrace" (magic header)
#   4. dotnet-trace convert succeeds without exceptions on stderr
#      (exit code 0 alone is insufficient — see header+garbage case)
#
# Usage (sourced):
#   source tools/validate-nettrace.sh
#   validate_nettrace /path/to/file.nettrace
#   # returns 0 (valid) or 1 (invalid)
#
# Usage (standalone):
#   ./tools/validate-nettrace.sh /path/to/file.nettrace
#   # exits 0 (valid) or 1 (invalid)
#
# Environment variables:
#   DOTNET_TRACE — Full command to invoke dotnet-trace (e.g. "dotnet /path/to/dotnet-trace.dll")
#                  If unset, the function discovers dotnet-trace automatically.
# =============================================================================

# Double-source guard
[ -n "${_VALIDATE_NETTRACE_LOADED:-}" ] && return 0 2>/dev/null
_VALIDATE_NETTRACE_LOADED=1

# ---------------------------------------------------------------------------
# Determine REPO_ROOT by walking up from this script's location
# ---------------------------------------------------------------------------
_VALIDATE_NETTRACE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VALIDATE_NETTRACE_REPO_ROOT="$(cd "$_VALIDATE_NETTRACE_SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# _resolve_dotnet_trace — find the dotnet-trace tool
#
# Sets _RESOLVED_DOTNET_TRACE to the command string, or empty if not found.
# ---------------------------------------------------------------------------
_resolve_dotnet_trace() {
    # Already resolved?
    if [ -n "${_RESOLVED_DOTNET_TRACE:-}" ]; then
        return 0
    fi

    # 1. Caller-provided DOTNET_TRACE env var
    if [ -n "${DOTNET_TRACE:-}" ]; then
        _RESOLVED_DOTNET_TRACE="$DOTNET_TRACE"
        return 0
    fi

    local tools_dir="$_VALIDATE_NETTRACE_REPO_ROOT/tools"
    local dotnet_dir="$_VALIDATE_NETTRACE_REPO_ROOT/.dotnet"

    # 2. DLL in the .store, run via local dotnet
    local dll
    dll=$(find "$tools_dir/.store/dotnet-trace" -name 'dotnet-trace.dll' -path '*/tools/net8.0/any/*' 2>/dev/null | head -1)
    if [ -n "$dll" ] && [ -f "$dotnet_dir/dotnet" ]; then
        _RESOLVED_DOTNET_TRACE="$dotnet_dir/dotnet $dll"
        return 0
    fi

    # 3. Native shim binary
    if [ -x "$tools_dir/dotnet-trace" ]; then
        _RESOLVED_DOTNET_TRACE="$tools_dir/dotnet-trace"
        return 0
    fi

    # Not found
    _RESOLVED_DOTNET_TRACE=""
    return 1
}

# ---------------------------------------------------------------------------
# validate_nettrace <file>
#
# Validates a .nettrace file. Prints diagnostics to stderr.
# Returns 0 if valid, 1 if invalid.
# ---------------------------------------------------------------------------
validate_nettrace() {
    local file="${1:-}"

    if [ -z "$file" ]; then
        echo "validate_nettrace: no file specified" >&2
        return 1
    fi

    # --- Check 1: File exists and is non-empty ---
    if [ ! -f "$file" ]; then
        echo "validate_nettrace: file does not exist: $file" >&2
        return 1
    fi

    if [ ! -s "$file" ]; then
        echo "validate_nettrace: file is empty: $file" >&2
        return 1
    fi

    # --- Check 2: Minimum size (8 KB) ---
    local file_size
    file_size=$(wc -c < "$file" | tr -d ' ')
    if [ "$file_size" -lt 8192 ]; then
        echo "validate_nettrace: file too small ($file_size bytes < 8192 bytes minimum): $file" >&2
        return 1
    fi

    # --- Check 3: Magic header ("Nettrace" in first 8 bytes) ---
    local header
    header=$(head -c 8 "$file" 2>/dev/null)
    if [ "$header" != "Nettrace" ]; then
        echo "validate_nettrace: invalid magic header (expected 'Nettrace', got '$(head -c 8 "$file" | cat -v)'): $file" >&2
        return 1
    fi

    # --- Check 4: dotnet-trace convert (exit code + stderr) ---
    _resolve_dotnet_trace
    if [ -z "${_RESOLVED_DOTNET_TRACE:-}" ]; then
        echo "validate_nettrace: WARNING: dotnet-trace not found, skipping conversion check" >&2
        # Don't fail — allow standalone use without tool installed
        return 0
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/validate-nettrace.XXXXXX")

    local stderr_file="$tmp_dir/stderr.txt"
    local convert_exit=0

    # Run conversion, capturing stderr separately
    # shellcheck disable=SC2086
    $_RESOLVED_DOTNET_TRACE convert --format speedscope --output "$tmp_dir/output.speedscope.json" "$file" \
        > /dev/null 2> "$stderr_file" || convert_exit=$?

    local is_valid=0  # assume valid

    if [ "$convert_exit" -ne 0 ]; then
        echo "validate_nettrace: dotnet-trace convert failed (exit code $convert_exit): $file" >&2
        if [ -s "$stderr_file" ]; then
            echo "  stderr: $(cat "$stderr_file")" >&2
        fi
        is_valid=1
    elif grep -qi "exception" "$stderr_file" 2>/dev/null; then
        echo "validate_nettrace: dotnet-trace convert exited 0 but stderr contains exception: $file" >&2
        echo "  stderr: $(cat "$stderr_file")" >&2
        is_valid=1
    fi

    # Clean up temp files
    rm -rf "$tmp_dir"

    return "$is_valid"
}

# ---------------------------------------------------------------------------
# Standalone mode: if executed directly (not sourced), validate the argument.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <file.nettrace>" >&2
        exit 1
    fi

    if validate_nettrace "$1"; then
        echo "VALID: $1"
        exit 0
    else
        echo "INVALID: $1"
        exit 1
    fi
fi
