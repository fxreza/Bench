#!/bin/bash
# Builds the two release zips and publishes them as the GitHub release for
# the version in Resources/Info.plist. Run after the version commit and its
# tag (vX.Y.Z) are pushed.
#
#   Bench-X.Y.Z-Apple-Silicon.zip   signed "Transi Dev", for the developer's
#                                   own Macs (permissions survive updates)
#   Bench-X.Y.Z-arm64-adhoc.zip     ad-hoc, for every other Mac
#
# Each installed copy updates from the zip signed like itself (see
# UpdateService.selectRelease). The ad-hoc name must never contain "Silicon":
# copies older than 0.4.1 take the first zip naming their arch.
#
# Usage: scripts/release.sh            build both zips and publish
#        BENCH_NO_PUBLISH=1 scripts/release.sh   build the zips only
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
OUT=dist/app.noindex
APP=build.noindex/Bench.app
SIGNED_ZIP="$OUT/Bench-$VERSION-Apple-Silicon.zip"
ADHOC_ZIP="$OUT/Bench-$VERSION-arm64-adhoc.zip"
mkdir -p "$OUT"

authority() { codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 || true; }

# Signed build first: it also installs into /Applications, as every build does.
./scripts/build-app.sh
[[ "$(authority)" == "Authority=Transi Dev" ]] || { echo "error: signed build is not Transi Dev"; exit 1; }
rm -f "$SIGNED_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SIGNED_ZIP"

# Ad-hoc build second; BENCH_DIST=1 never installs it here.
BENCH_DIST=1 ./scripts/build-app.sh
[[ -z "$(authority)" ]] || { echo "error: dist build is not ad-hoc"; exit 1; }
rm -f "$ADHOC_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ADHOC_ZIP"

ls -la "$SIGNED_ZIP" "$ADHOC_ZIP"

if [ "${BENCH_NO_PUBLISH:-0}" = "1" ]; then
    echo "Skipped publishing (BENCH_NO_PUBLISH=1)."
    exit 0
fi

# Release notes: which zip to download, then this version's CHANGELOG section.
NOTES=$(mktemp)
{
    echo "**Download \`Bench-$VERSION-arm64-adhoc.zip\`** (Apple silicon). Move Bench.app to Applications;"
    echo "on first launch allow it under System Settings > Privacy & Security > Open Anyway."
    echo "After each update, turn Bench off and on again under Accessibility and Screen Recording."
    echo "\`Bench-$VERSION-Apple-Silicon.zip\` is signed for the developer's own Macs and will not keep its permissions on yours."
    echo
    awk -v v="## $VERSION " 'index($0, v) == 1 { on = 1; next } on && /^## / { exit } on' CHANGELOG.md
} > "$NOTES"

gh release create "$TAG" "$SIGNED_ZIP" "$ADHOC_ZIP" --title "Bench $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
