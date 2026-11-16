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
    MODULES=(BenchCore Shot Klip Lingo Snap Piko Tap Clean)
fi

STATUS=0
for m in "${MODULES[@]}"; do
    echo "== ${m}Tests"
    # One product per `swift build`: given several --product flags, SwiftPM
    # builds only the last one, and the others would run a stale binary.
    # --product (not --target) so the runner executable is relinked after an
    # edit. A failed build fails the module instead of running the old runner.
    if ! log=$(swift build --scratch-path "$SCRATCH" --product "${m}Tests" 2>&1); then
        echo "$log" | grep -E "error:" || echo "$log" | tail -20
        echo "FAIL ${m}Tests did not build"
        STATUS=1
        continue
    fi
    echo "$log" | grep -E "warning: unused" || true
    if ! "$SCRATCH/debug/${m}Tests"; then STATUS=1; fi
done
exit $STATUS
