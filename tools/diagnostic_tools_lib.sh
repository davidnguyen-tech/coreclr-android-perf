#!/bin/bash
# =============================================================================
# tools/diagnostic_tools_lib.sh — Shared helper functions for resolving .NET
# diagnostic tool paths (dotnet-trace, dotnet-dsrouter).
#
# This library is sourced by the platform-specific nettrace collection scripts:
#   - android/collect_nettrace.sh
#   - ios/collect_nettrace.sh
#   - osx/collect_nettrace.sh
#   - maccatalyst/collect_nettrace.sh
#
# Prerequisites:
#   - $TOOLS_DIR and $LOCAL_DOTNET must be set (provided by init.sh).
#
# NOTE: This file is a pure function library. No code executes at source time.
# =============================================================================

# Double-source guard
[ -n "${_DIAGNOSTIC_TOOLS_LIB_LOADED:-}" ] && return 0
_DIAGNOSTIC_TOOLS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# resolve_tool_dll <tool-name>
#   Dynamically locate a .NET global tool's DLL inside the .store directory.
#   Returns the first matching path, or empty string if none found.
#
#   We prefer running via 'dotnet <tool>.dll' over the native apphost wrapper
#   because on macOS the apphost binaries acquire com.apple.provenance, and
#   amfid can SIGKILL them during long-running operations.  Running through
#   the already-signed dotnet binary avoids this.
# ---------------------------------------------------------------------------
resolve_tool_dll() {
    local tool_name="$1"
    local pattern="$TOOLS_DIR/.store/${tool_name}/*/${tool_name}/*/tools/*/any/${tool_name}.dll"
    local match
    # Use a glob to find the DLL regardless of installed version or TFM
    for match in $pattern; do
        if [ -f "$match" ]; then
            echo "$match"
            return 0
        fi
    done
    echo ""
    return 0
}

# ---------------------------------------------------------------------------
# resolve_dotnet_trace
#   Sets the global DOTNET_TRACE variable to the command for running
#   dotnet-trace.  Prefers the DLL path (via $LOCAL_DOTNET) over the native
#   apphost wrapper to avoid the amfid issue described above.
#   Returns 1 if the tool is not installed.
# ---------------------------------------------------------------------------
resolve_dotnet_trace() {
    local dll_path
    dll_path=$(resolve_tool_dll "dotnet-trace")

    if [ -n "$dll_path" ]; then
        DOTNET_TRACE="$LOCAL_DOTNET $dll_path"
    else
        DOTNET_TRACE="$TOOLS_DIR/dotnet-trace"
    fi

    if [ -z "$dll_path" ] && [ ! -f "$TOOLS_DIR/dotnet-trace" ]; then
        echo "Error: dotnet-trace not found. Run ./prepare.sh to install it."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# resolve_dsrouter
#   Sets the global DSROUTER variable to the command for running
#   dotnet-dsrouter.  Prefers the DLL path (via $LOCAL_DOTNET) over the native
#   apphost wrapper to avoid the amfid issue described above.
#   Returns 1 if the tool is not installed.
# ---------------------------------------------------------------------------
resolve_dsrouter() {
    local dll_path
    dll_path=$(resolve_tool_dll "dotnet-dsrouter")

    if [ -n "$dll_path" ]; then
        DSROUTER="$LOCAL_DOTNET $dll_path"
    else
        DSROUTER="$TOOLS_DIR/dotnet-dsrouter"
    fi

    if [ -z "$dll_path" ] && [ ! -f "$TOOLS_DIR/dotnet-dsrouter" ]; then
        echo "Error: dotnet-dsrouter not found. Run ./prepare.sh to install it."
        return 1
    fi
}
