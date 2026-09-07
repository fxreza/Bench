#!/bin/bash
# Builds debug and runs every module's test runner. No XCTest, no Xcode.
#
# Usage: scripts/run_tests.sh [Module ...]        e.g. scripts/run_tests.sh Snap Shot
#   BENCH_TEST_FILTER=substring  runs only matching tests
#   SCRATCH=.build-foo           use a separate SwiftPM scratch path
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${SCRATCH:-.build}"
MODULES=("$@")
if [[ ${#MODULES[@]} -eq 0 ]]; then
    MODULES=(BenchCore Shot Klip Lingo Snap Piko)
fi

TARGETS=()
# --product (not --target) so the runner executable is relinked after an edit.
for m in "${MODULES[@]}"; do TARGETS+=(--product "${m}Tests"); done

swift build --scratch-path "$SCRATCH" "${TARGETS[@]}" 2>&1 | grep -E "error:|warning: unused|Build complete|Compiling" | grep -v "^\[" || true

STATUS=0
for m in "${MODULES[@]}"; do
    echo "== ${m}Tests"
    if ! "$SCRATCH/debug/${m}Tests"; then STATUS=1; fi
done
exit $STATUS
