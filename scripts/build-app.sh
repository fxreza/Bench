#!/bin/bash
# Builds build.noindex/Bench.app from the SwiftPM executable, signs it, and
# installs it into /Applications. Modelled on Transi's scripts/build-app.sh.
#
#   scripts/build-app.sh                 release build, sign, install
#   BENCH_NO_INSTALL=1 scripts/build-app.sh   build only, leave /Applications alone
#   BENCH_DIST=1 scripts/build-app.sh    ad-hoc signature for another Mac, no install
#   scripts/build-app.sh debug           build the debug configuration instead
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Bench"
BUNDLE_ID="com.fxreza.bench"
CONFIG="${1:-release}"
APP="build.noindex/${APP_NAME}.app"
INSTALLED="/Applications/${APP_NAME}.app"

# `--product Bench` rather than a bare `swift build`: the package also holds the
# per-module test runners, which `@testable import` their module and so cannot
# be compiled in release. Building the app product pulls in exactly the app and
# the four modules it depends on.
swift build -c "$CONFIG" --product "$APP_NAME"
BIN=".build/${CONFIG}/${APP_NAME}"

# MARK: - Assemble

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon. Regenerate with: swift scripts/make-icon.swift
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "Warning: Resources/AppIcon.icns missing - run 'swift scripts/make-icon.swift'"
fi

# MIT requires the copyright notices of everything bundled to travel with any
# distribution, so the .app carries them too - not just the repo. CHANGELOG.md
# is also what ChangelogService reads for the What's New window.
for doc in LICENSE ATTRIBUTION.md CHANGELOG.md; do
    [ -f "$doc" ] && cp "$doc" "$APP/Contents/Resources/$doc"
done

# Every module resource bundle SwiftPM produced. `Bundle.module` looks for
# these next to the main bundle's resources, so Contents/Resources is where a
# .app has to keep them; without this a module's images, sounds and .strings
# are simply missing at runtime.
BUNDLE_COUNT=0
for bundle in .build/"$CONFIG"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
    BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
echo "Copied ${BUNDLE_COUNT} module resource bundle(s)."

# MARK: - Sign

# A stable local identity so TCC (Accessibility / Screen Recording) grants
# survive rebuilds. An ad-hoc signature gets a new hash every build, so macOS
# treats each rebuild as a different app and silently drops the grants. The
# identity is shared with Transi - it is just a self-signed code-signing
# certificate in this Mac's keychain, and Bench has no reason to make a second.
#
# BENCH_DIST=1 signs ad-hoc instead: the "Transi Dev" certificate is
# self-signed and lives only here, so on any OTHER Mac its chain cannot be
# built and the signature reads as invalid - TCC then refuses to register the
# app at all. An ad-hoc signature validates anywhere.
sign() {
    codesign --force --deep --entitlements Bench.entitlements --sign "$1" "$APP"
}

if [ "${BENCH_DIST:-0}" = "1" ]; then
    sign -
    echo "Signed ad-hoc for distribution to another Mac (BENCH_DIST=1)."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Transi Dev"; then
    sign "Transi Dev"
    echo "Signed with local identity: Transi Dev"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Bench Dev"; then
    sign "Bench Dev"
    echo "Signed with local identity: Bench Dev"
else
    sign -
    echo "Signed ad-hoc (no 'Transi Dev' or 'Bench Dev' identity in the keychain)."
    echo "Accessibility/Screen Recording grants will reset on every rebuild until"
    echo "you create a stable identity - see README.md > Signing."
fi

echo "Authority: $(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 || echo 'none (ad-hoc)')"
echo "Built $APP"

# MARK: - Install

if [ "${BENCH_DIST:-0}" = "1" ]; then
    # A dist build is for another machine; installing it here would replace the
    # locally-signed copy and drop this Mac's own permission grants.
    echo "Skipped install (BENCH_DIST=1). Copy $APP to the other Mac, move it to"
    echo "/Applications there, then run: xattr -dr com.apple.quarantine $INSTALLED"
    exit 0
fi

if [ "${BENCH_NO_INSTALL:-0}" = "1" ]; then
    echo "Skipped install (BENCH_NO_INSTALL=1)."
    echo "Run:  open $APP"
    exit 0
fi

# Only ever replace our own app - never clobber an unrelated bundle that
# happens to share the name.
if [ -e "$INSTALLED" ]; then
    EXISTING_ID=$(defaults read "$INSTALLED/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "")
    if [ "$EXISTING_ID" != "$BUNDLE_ID" ]; then
        echo "Refusing to replace $INSTALLED - it is not Bench"
        echo "(bundle id: '${EXISTING_ID:-unknown}'). Remove it by hand first."
        exit 1
    fi
fi

# The running copy holds its executable open; quit it before swapping, and
# bring it back afterwards if it was running.
WAS_RUNNING=0
if pgrep -f "$INSTALLED/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    WAS_RUNNING=1
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    pkill -f "$INSTALLED/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 || true
    sleep 1
fi

rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
echo "Installed $INSTALLED"

if [ "$WAS_RUNNING" = "1" ]; then
    open "$INSTALLED"
    echo "Relaunched the running copy."
else
    echo "Run:  open $INSTALLED"
fi
