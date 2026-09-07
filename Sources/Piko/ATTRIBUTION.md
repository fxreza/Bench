# Piko - attribution

The Piko module is the standalone Piko app (`../Piko`, MIT, Copyright 2026 Sam
Reza) ported into Bench. Two things in it are not ours.

## mediaremote-adapter (bundled, BSD 3-Clause)

- Upstream: <https://github.com/ungive/mediaremote-adapter>
- Author: Jonas van den Berg (`ungive`) and contributors, Copyright (c) 2025
- Version: v0.7.6 (commit `3ac3d4b`)
- License: BSD 3-Clause. The full text ships next to the binaries, at
  `Sources/Piko/Resources/MediaRemoteAdapter/LICENSE`, and is reproduced in the
  standalone Piko's `THIRD-PARTY-LICENSES.md` together with the exact clang
  command the bundled framework was built with (upstream publishes no binary
  release).

Bundled files, copied verbatim into the module bundle:

```
Sources/Piko/Resources/MediaRemoteAdapter/mediaremote-adapter.pl
Sources/Piko/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework
Sources/Piko/Resources/MediaRemoteAdapter/LICENSE
```

MediaRemote stopped answering "what is playing" for unentitled processes in
macOS 15.4. The adapter is the workaround: `/usr/bin/perl` - a platform binary
`mediaremoted` still trusts - `dlopen`s the small helper framework and streams
now-playing JSON on stdout. Bench never links the framework; it only passes its
path to the perl script, which runs as a subprocess (`NowPlaying/
MediaRemoteAdapter.swift`). Playback *control* does not go through it:
`MRMediaRemoteSendCommand` was never gated and is called in-process
(`NowPlaying/MediaRemoteBridge.swift`).

## Alcove - design reference, no code

Piko's geometry, radii and animation timings were measured from
[Alcove](https://tryalcove.com) on a 16" MacBook Pro and are written down in
the standalone Piko's `docs/research/alcove-measurements.md`. Alcove is a
commercial app: nothing was decompiled, and no Alcove code, asset or resource
is present here. Only the measurements are - the numbers in
`Core/Models.swift` (`NotchMetrics`) and the springs in
`Notch/NotchViewModel.swift`.

The private WindowServer space trick in `Notch/NotchSpace.swift`
(`SLSSpaceCreate` + `SLSSpaceSetAbsoluteLevel`, so a trackpad space swipe does
not drag the notch along) is the approach Alcove and the open-source
`boring.notch` both use; the implementation here is our own.
