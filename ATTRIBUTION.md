# Attribution

Bench is assembled from four apps by the same author, plus the projects those
apps were themselves built on. Everything below is MIT-licensed except
mediaremote-adapter (BSD-3-Clause); the notices those licenses require to
travel with a distribution are reproduced at the end, and this file ships
inside the built `.app` as well as in the repo.

## The four apps Bench is made of

| Module | Comes from | Copyright | Where |
|---|---|---|---|
| Shot | Snapper | 2026 Sam Reza | https://github.com/fxreza/Snapper |
| Klip | Klip | 2026 Sam Reza | https://github.com/fxreza/Klip |
| Lingo | Transi | 2026 Sam Reza | https://github.com/fxreza/Transi |
| Piko | Piko | 2026 Sam Reza | https://github.com/fxreza/Piko |

Snap is new in Bench; it replaces a set of BetterTouchTool window-management
triggers and borrows no code.

Piko bundles [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
by ungive (BSD-3-Clause; notice below and in `Sources/Piko/ATTRIBUTION.md`)
to read now-playing information, which macOS 15.4+ gates for third-party
apps. Its geometry and timing were measured from Alcove, a closed-source app;
no code of it was used.

The app shell also carries pieces of all four: the updater and changelog
parser from Snapper (which took them from Klip), the hotkey registration,
shortcut store, permissions polling, appearance settings and hotkey recorder
that all three shared, and Transi's build, icon and launch scripts.

## What those three were built on

### Buffer

Copyright (c) 2026 Samir Patil - MIT.

Klip is a fork of Buffer: the core clipboard manager architecture, pasteboard
monitoring and history management came from it, and reach Bench through Klip.

### Clipfield

Copyright (c) 2026 Alex Jolley - MIT.

Klip ported and adapted design tokens and UI components from Clipfield, several
of which are now in `BenchCore`:

- theme tokens and light/dark + accent handling (`Appearance.swift`)
- the keyboard shortcut recorder (`HotkeyRecorder.swift`)
- Accessibility permission polling (`PermissionsState.swift`)
- the first-launch permission request, now Bench's Permissions pane
- rich text format detection, link/email/phone/color/code detection heuristics
- the sidebar resize control

### Pesty

Copyright (c) 2026 Moamen Basel - MIT.

Klip's iCloud Drive file sync approach - per-device snapshot files,
content-hash deduplication, tombstone-based deletion tracking and
`NSFileCoordinator` coordination - came from Pesty and is used by the Klip
module.

### SelectedTextKit, AXSwift, KeySender

Linked by the Lingo module for selected-text capture, exactly as Transi linked
them.

| Package | Author | Where |
|---|---|---|
| SelectedTextKit | tisfeng | https://github.com/tisfeng/SelectedTextKit |
| AXSwift | Tyler Mandry | https://github.com/tmandry/AXSwift (via SelectedTextKit) |
| KeySender | Jordan Baird | https://github.com/jordanbaird/KeySender (via SelectedTextKit) |

Translation results come from Google Translate, Bing and Gemini. None of those
companies is affiliated with Bench or endorses it.

## Studied for behaviour only - no code copied

Read to understand how they behave, not for their source. Nothing in Bench is
derived from their code:

- **MacShot** (GPLv3)
- **Capso** (Business Source License 1.1 - forbids screenshot-app derivatives)
- **Shottr** (closed source; behaviour reverse-engineered from screenshots,
  UserDefaults keys and binary strings only)

--------------------------------------------------------------------------------
## SelectedTextKit

MIT License

Copyright (c) 2024 tisfeng

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
## AXSwift

MIT License

Copyright (c) 2017 Tyler Mandry

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
## KeySender

MIT License

Copyright (c) 2022 Jordan Baird - https://github.com/jordanbaird/KeySender

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
