# Bench - working rules

## Build and install

```bash
./scripts/build-app.sh     # swift build -c release, bundle, sign, install to /Applications/Bench.app
./scripts/run_tests.sh     # debug build + every <Module>Tests runner
```

A code change is not done until `/Applications/Bench.app` is rebuilt; that is
the copy the user runs.

## Output directories end in `.noindex`

`build.noindex/` and `dist/app.noindex/` keep Spotlight from indexing a second
`Bench.app` next to the installed one. Do not rename them and do not add an
output directory without the suffix.

## Menu-bar app launch trap (macOS 26)

Launch dev builds only with `open /path/to/Bench.app` (never the bare
binary) and never run two live copies of `com.fxreza.bench` at once. A binary
launched straight from a Terminal or Claude Code session is attributed to
that launcher by ControlCenter, and if the launcher's own menu bar icon is
hidden, every status item with this bundle id stops being laid out. Full
record: `/Users/sam/Claude/CLAUDE.md` and Klip's
`docs/analysis/menubar-status-item-not-laid-out.md`.

## Signing

`scripts/build-app.sh` signs with the local `Transi Dev` identity (any stable
local identity works; ad-hoc signatures change every build and macOS then
drops the Accessibility and Screen Recording grants). `BENCH_DIST=1` signs
ad-hoc for a copy meant for another Mac.

## Module boundaries

One public type per module (`<Module>Feature`). Shared code goes in
`BenchCore`, not into another module. Keys, action ids and data folders are
namespaced per module. See `docs/ARCHITECTURE.md`.

The standalone apps in `../Klip`, `../Snapper`, `../Transi` are the
originals Bench was assembled from. They are kept as they are; never edit
them from this repo, and never write into their preferences domains or
Application Support folders.
