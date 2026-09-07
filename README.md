# Bench

One macOS menu bar app that does four things, so four apps do not have to.
Bench replaces Klip, Snapper and Transi, and the window-management triggers
that used to live in BetterTouchTool, with a single icon, one Settings window,
one shortcut list and one updater.

Each capability is a **module**: Shot, Klip, Lingo and Snap. A module can be
switched off, and a module that is off holds no shortcuts, no event taps, no
timers and no windows - it costs nothing but the disk space.

## The modules

### Shot - screenshots and annotation

Area, window, full-screen and scrolling capture, with an annotation editor for
arrows, boxes, text, highlights and redaction. Captures follow the macOS
screenshot destination and folder; the file format comes from the shortcut you
press, so the same key with ⌥ writes a JPG instead of a PNG.

| Action | Shortcut | With ⌥ |
|---|---|---|
| Capture area | ⇧⌘4 | ⌥⇧⌘4 (JPG) |
| Capture window | ⇧⌘6 | ⌥⇧⌘6 (JPG) |
| Capture full screen | ⇧⌘3 | ⌥⇧⌘3 (JPG) |
| Scrolling capture | ⇧⌘2 | ⌥⇧⌘2 (JPG) |
| Repeat last capture | ⇧⌘1 | ⌥⇧⌘1 (JPG) |

### Klip - clipboard history

Everything you copy, searchable, with folders, tags, pinning and a trash.
Handles text, rich text, images, colors and files, keeps a preview of each, and
pastes straight back into the app you were in. Syncs between your Macs through
iCloud Drive when you turn that on.

| Action | Shortcut |
|---|---|
| Open clipboard history | ⇧⌘V |

### Lingo - translation

Point at text anywhere and translate it: the selection if there is one, the UI
element under the pointer if there is not, OCR of the pixels around it if that
fails too, and a typing field if there is nothing at all. Google, Bing and
Gemini side by side, plus speech and clipboard translation.

| Action | Shortcut |
|---|---|
| Translate selection / under pointer | ⌥T |
| Screenshot and translate | ⌥S |
| Read selection aloud | ⌥R |
| Translate clipboard | ⌥C |

### Snap - window management

Move and resize the frontmost window from the keyboard: halves, quarters,
thirds and two-thirds, maximize, restore and center, plus a jump back to the
previous window and two scripted shortcuts.

| Action | Shortcut | | Action | Shortcut |
|---|---|---|---|---|
| Left half | ⌃⌘← | | Top left quarter | ⌃⌘[ |
| Right half | ⌃⌘→ | | Top right quarter | ⌃⌘] |
| Top half | ⌃⌘↑ | | Bottom left quarter | ⌃⌘; |
| Bottom half | ⌃⌘↓ | | Bottom right quarter | ⌃⌘' |
| Maximize | ⌃⌘↩ | | First third | ⌃⌘I |
| Restore | ⌃⌘⌫ | | Center third | ⌃⌘O |
| Center | ⌃⌘C | | Last third | ⌃⌘P |
| Previous window | ⌥⇥ | | First two thirds | ⌃⌘J |
| Terminal here | ⌃⌘T | | Center two thirds | ⌃⌘K |
| Downloads | ⌘E | | Last two thirds | ⌃⌘L |

Every shortcut above is a default. Settings > Shortcuts lists all of them
together and lets you rebind or clear any one; a combination another action
already holds is refused, and one macOS itself owns is reported on the row.

## Requirements

macOS 14 or later, Apple silicon or Intel. No Xcode needed to build - the
Command Line Tools are enough.

## Build and install

```bash
./scripts/build-app.sh          # release build, sign, install to /Applications/Bench.app
BENCH_NO_INSTALL=1 ./scripts/build-app.sh   # build into build.noindex/ only
./scripts/run_app.sh            # run the local build with a scratch data dir
./scripts/run_tests.sh          # debug build + every module's test runner
swift scripts/make-icon.swift   # regenerate Resources/AppIcon.icns
```

A code change is not done until `/Applications/Bench.app` has been rebuilt;
that is the copy you actually run.

Never run the installed copy and a local build at the same time. They share a
bundle identifier, and macOS tracks menu bar items per identifier - two live
copies can leave the status item registered but never drawn. `run_app.sh`
refuses to launch while the installed copy is running.

## Signing

`build-app.sh` signs with the local self-signed `Transi Dev` identity (any
stable local identity works; `Bench Dev` is accepted too). This matters: an
ad-hoc signature gets a new hash on every build, so macOS treats each rebuild
as a different app and silently drops the Accessibility and Screen Recording
grants you just made. Create the certificate once in Keychain Access
(Certificate Assistant > Create a Certificate, type "Code Signing", self
signed) and every rebuild keeps its permissions.

`BENCH_DIST=1 ./scripts/build-app.sh` signs ad-hoc instead, for a copy meant
for another Mac: a self-signed identity's chain cannot be built there, so the
signature would read as invalid and TCC would refuse to register the app at
all.

## Permissions

| Permission | What needs it |
|---|---|
| Accessibility | Klip's paste-into-the-app-you-were-in, Lingo's selected-text capture, Snap's window moves |
| Screen Recording | Shot's captures, Lingo's screenshot translate |
| Automation | Reading the selection out of a browser, and Snap's scripted shortcuts. Granted one target app at a time, the first time Bench scripts it |

Settings > Permissions shows the state of each, grants it, and deep-links into
the right System Settings pane. Bench asks for nothing on launch beyond the
first one, and only ever for what an enabled module needs.

## Coming from Klip, Snapper or Transi

Bench replaces all three. On first launch it **copies** their settings and data
into its own preferences and `~/Library/Application Support/Bench` - copy only:
the old apps' preference domains and folders are read and never written,
deleted or moved, so they keep working exactly as before.

Two things Bench cannot do for you:

1. **Quit them.** They register the same global shortcuts Bench does, and two
   apps cannot own one combination - whichever got there first keeps it, and
   the other looks broken. Bench offers to quit them once, on launch.
2. **Turn off their Launch at Login.** Open each of Klip, Snapper and Transi
   and switch it off there, or they come back at the next login.

Once Bench has imported what it needs you can move the three apps to the
Trash.

## License

MIT - see `LICENSE`. Bench is assembled from Snapper, Klip and Transi and the
projects those were built on; see `ATTRIBUTION.md`.
