# Snap

Window management: the BetterTouchTool triggers this Mac used to carry,
rebuilt as a Bench module. Sixteen layouts, a previous-window switch, a title
bar double-click gesture and two AppleScripts.

## Shortcuts

Caps Lock is remapped to **Right Control** in System Settings, so every
"Caps+⌘X" below is physically ⌃⌘X. BetterTouchTool could tell the right
Control key from the left one; Carbon hot keys cannot, so Bench registers
plain ⌃⌘ and **either** Control key triggers the action.

| Action id | Title | Default | Key code | What it does |
|---|---|---|---|---|
| `snap.leftHalf` | Left Half | ⌃⌘← | 123 | fills the left half of the screen's visible frame |
| `snap.rightHalf` | Right Half | ⌃⌘→ | 124 | right half |
| `snap.topHalf` | Top Half | ⌃⌘↑ | 126 | top half |
| `snap.bottomHalf` | Bottom Half | ⌃⌘↓ | 125 | bottom half |
| `snap.maximize` | Maximize | ⌃⌘↩ | 36 | fills the visible frame (not native full screen) |
| `snap.restore` | Restore Previous Size | ⌃⌘⌫ | 51 | back to the frame the window had before Snap first moved it |
| `snap.center` | Center | ⌃⌘C | 8 | keeps the size, centres it in the visible frame |
| `snap.topLeft` | Top Left Quarter | ⌃⌘[ | 33 | |
| `snap.topRight` | Top Right Quarter | ⌃⌘] | 30 | |
| `snap.bottomLeft` | Bottom Left Quarter | ⌃⌘; | 41 | |
| `snap.bottomRight` | Bottom Right Quarter | ⌃⌘' | 39 | |
| `snap.leftThird` | Left Third | ⌃⌘I | 34 | |
| `snap.middleThird` | Middle Third | ⌃⌘O | 31 | |
| `snap.rightThird` | Right Third | ⌃⌘P | 35 | |
| `snap.leftTwoThirds` | Left Two Thirds | ⌃⌘J | 38 | |
| `snap.centerTwoThirds` | Center Two Thirds | ⌃⌘K | 40 | two-thirds wide, full height, centred horizontally (BTT ran "Left Two Thirds" then "Center Window") |
| `snap.rightTwoThirds` | Right Two Thirds | ⌃⌘L | 37 | |
| `snap.previousWindow` | Activate Previous Window | ⌥⇥ | 48 | switches to the window focused before the current one; press again to flip back (BTT's "Cycle Two Windows") |
| `snap.terminalScript` | New Terminal Window | ⌃⌘T | 17 | runs the Terminal AppleScript from Settings |
| `snap.downloadsScript` | Open Downloads in Finder | ⌘E | 14 | runs the Finder AppleScript from Settings |

`⌘E` is a global hot key: it fires ahead of any app's own ⌘E menu item.
Rebind it in Settings > Snap > Shortcuts if that gets in the way.

## Title bar double-click

`snap.titlebarDoubleClick` (default on). A listen-only
`CGEvent` session tap watches `.leftMouseDown` events whose
`.mouseEventClickState` is 2; the click is never delayed or swallowed. The
element under the click comes from `AXUIElementCopyElementAtPosition`, and the
click counts as a title bar hit when it lands in the top 30 points of the
enclosing window's frame on something that is not a control (button, tab, text
field, popup, search field…). Clicks with ⌘⌥⌃⇧ held are ignored.

The first double-click maximizes, the next restores the previous size, and so
on - BTT's two cycling actions. `snap.titlebarDoubleClickRestores` turns the
restore half off, so every double-click maximizes.

macOS has its own "double-click a window's title bar to" setting (System
Settings > Desktop & Dock). It is **None** on this Mac, so nothing else reacts
to the gesture; set to Zoom or Minimize, both would happen.

The tap needs Accessibility, so it is installed only once
`PermissionsState.accessibilityTrusted` is true and re-armed from
`onAccessibilityBecameTrusted`.

## Not ported from BetterTouchTool

- **Unpin Focused Window To NOT Float On Top.** Undoing "float on top" relies
  on BTT's private window-level manipulation; Accessibility exposes no
  equivalent, so there is nothing to port.
- **The three "Menubar Item: │" separators.** Cosmetic dividers inside BTT's
  own menu bar. Bench's status menu builds its own sections.

Both are also stated in the Snap Settings pane, so the absence is visible
where the user looks for them.

## Preferences

| Key | Default | Meaning |
|---|---|---|
| `snap.gap` | 0 | points between a window and the screen edges, and between two windows side by side |
| `snap.titlebarDoubleClick` | on | install the double-click tap |
| `snap.titlebarDoubleClickRestores` | on | the second double-click restores instead of maximizing again |
| `snap.script.terminal` | see below | AppleScript for ⌃⌘T |
| `snap.script.downloads` | see below | AppleScript for ⌘E |

Shipped scripts (both editable in Settings, with a Reset and a Run button):

```applescript
-- snap.script.terminal
if application "Terminal" is running then
    tell application "Terminal"
        do script ""
        activate
    end tell
else
    tell application "Terminal"
        activate
    end tell
end if
```

```applescript
-- snap.script.downloads
tell application "Finder"
    set newWindow to make new Finder window
    set target of newWindow to folder "Downloads" of home
    activate
end tell
```

They run through `NSAppleScript` on a background queue, so a slow app launch
never blocks the hotkey. Errors raise an alert when the action came from the
menu or the Run button, and are logged otherwise. The first run against
Terminal or Finder raises the system Automation prompt, so the app bundle needs
`NSAppleEventsUsageDescription` in its `Info.plist`.

## Coordinate spaces

- `SnapLayout` and `NSScreen.visibleFrame` are **Cocoa**: bottom-left origin
  on the primary screen, y up.
- Accessibility (`kAXPositionAttribute`) and `CGEvent.location` are
  **top-left origin**, y down.

`SnapGeometry.flipRect/flipPoint` convert by mirroring about the *primary*
screen's height (`NSScreen.screens.first!.frame.maxY`) - never about the
screen the window is on, whose frame is already stated in the primary-anchored
space. The flip is its own inverse. Every read flips AX → Cocoa immediately;
the single flip back happens in `WindowController.setFrame`, which writes
**size, then position, then size again**: apps with a minimum size or a
character grid (Terminal) clamp the first write, and the second pass re-applies
what they rounded away.

## Files

| File | Holds |
|---|---|
| `SnapLayout.swift` | pure geometry: every placement, the gap arithmetic |
| `SnapGeometry.swift` | the AX/Cocoa flip and the screen-for-a-window choice |
| `WindowController.swift` | Accessibility reads and writes, window identity, apply/restore |
| `RestoreMemory.swift` | pre-Snap frames, keyed by pid + `CGWindowID`, capped at 64 |
| `FocusHistory.swift` | focus tracking for Activate Previous Window |
| `TitleBarClickWatcher.swift` | the event tap and the title bar hit rule |
| `ScriptRunner.swift` | `NSAppleScript` off the main thread |
| `SnapSettings.swift` / `SnapSettingsView.swift` | the `snap.` preferences and the pane |
| `SnapFeature.swift` | the `BenchFeature`: action table, lifecycle, Window submenu |
