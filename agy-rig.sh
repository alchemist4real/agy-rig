#!/usr/bin/env bash
# AGY RIG — Native POSIX Bash Runner
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
    exec python3 "${SCRIPT_DIR}/agy-rig" "$@"
elif command -v python >/dev/null 2>&1; then
    exec python "${SCRIPT_DIR}/agy-rig" "$@"
else
    echo "Error: Python 3 is required to run AGY RIG." >&2
    exit 1
fi
