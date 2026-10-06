@AGENTS.md

# Releasing Bench

Every release publishes **two zips**, never one. Use the script; do not
build, zip or upload by hand:

```bash
# after the version bump (Resources/Info.plist), CHANGELOG.md, commit, tag vX.Y.Z, push
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ./scripts/release.sh
```

| Zip | Signed | For |
|---|---|---|
| `Bench-X.Y.Z-Apple-Silicon.zip` | `Transi Dev` (self-signed, only in this Mac's keychain) | the developer's own Macs |
| `Bench-X.Y.Z-arm64-adhoc.zip` | ad-hoc | every other Mac, anyone downloading from GitHub |

Why: the updater only installs a zip signed exactly like the running copy
(`UpdateService.identityMismatchReason`). A `Transi Dev` build cannot be
verified on another Mac, so other Macs run the ad-hoc build, and each copy
updates from the zip that matches it (`UpdateService.selectRelease`,
`isAdHocAsset`).

Rules when changing anything near releases, signing, the updater or the build:

- Keep both zips in every release. A release with only one leaves the other
  kind of install unable to update.
- The ad-hoc zip's name must contain `adhoc` and must never contain `Silicon`
  (or `Intel`): copies older than 0.4.1 take the first zip naming their arch,
  and must keep finding the `Transi Dev` one.
- Keep the asset names, `isAdHocAsset` and `scripts/release.sh` in step; if
  one changes, change the others in the same commit.
- The release notes start with which zip to download (the script writes this).
- Without an Apple Developer ID there is no way around "Open Anyway" on first
  launch, or re-granting Accessibility and Screen Recording after each
  ad-hoc update. Do not promise otherwise.
