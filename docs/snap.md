# Snap

Window management: the BetterTouchTool triggers this Mac used to carry,
rebuilt as a Bench module. Sixteen layouts, three Raycast-style resizes, a
previous-window switch and two AppleScripts.

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
| `snap.restore` | Restore Previous Size | ⌃⌘⌫ | 51 | back to the frame the window had before Snap last changed it; press again to flip forward again |
| `snap.almostMaximize` | Almost Maximize | ⌃⌘M | 46 | `snap.almostMaximizePercent` of the visible frame, centred (Raycast's Almost Maximize) |
| `snap.larger` | Make Larger | ⌃⌘= | 24 | grows width and height by `snap.resizeStep`, centre kept, pushed back inside the screen at an edge |
| `snap.smaller` | Make Smaller | ⌃⌘- | 27 | shrinks the same way, never below 100 x 100 |
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

## Restore

Restore works the way Raycast's does. Every change Snap makes to a window - a
layout, Make Larger / Smaller, Almost Maximize, a modifier-key move or
resize - first records the frame the window had *just before* it, replacing
any earlier record. So Restore always goes back one step, whatever the window
looked like in between, including a move the user made by hand. Restore
itself records the frame it is leaving, so pressing it again flips forward,
and repeated presses alternate between the last two states.

Only Snap's own changes are recorded. A window dragged or resized by hand and
never touched by Snap has nothing to restore to, and a change made by hand
*after* a Snap change is not a step of its own: Restore returns to the
pre-Snap frame, and a second press comes back to the hand-made one.

A change that would not move the window (Maximize on an already maximized
window) records nothing, so it cannot overwrite a useful memory with a copy
of the current frame.

## Not ported from BetterTouchTool

- *Unpin Focused Window To NOT Float On Top* - needs BTT's private
  window-level tricks; no Accessibility equivalent.
- *Doubleclick Window Titlebar* (maximize, then restore) - left out on
  request.
- The three *Menubar Item: │* separators - cosmetic dividers in BTT's own
  menu bar.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `snap.gap` | 0 | points between a window and the screen edges, and between two windows side by side |
| `snap.resizeStep` | 60 | points Make Larger adds to, and Make Smaller takes from, each dimension per press (clamped to 1...1000) |
| `snap.almostMaximizePercent` | 90 | Almost Maximize's width and height as a percentage of the visible frame (clamped to 10...100) |
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
    activate
    open folder "Downloads" of home
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
| `SnapResize.swift` | pure geometry: Make Larger / Smaller and Almost Maximize |
| `SnapGeometry.swift` | the AX/Cocoa flip and the screen-for-a-window choice |
| `WindowController.swift` | Accessibility reads and writes, window identity, apply/restore |
| `RestoreMemory.swift` | the frame before the last Snap change, keyed by pid + `CGWindowID`, capped at 64; `swap` is Restore |
| `FocusHistory.swift` | focus tracking for Activate Previous Window |
| `ScriptRunner.swift` | `NSAppleScript` off the main thread |
| `SnapSettings.swift` / `SnapSettingsView.swift` | the `snap.` preferences and the pane |
| `SnapFeature.swift` | the `BenchFeature`: action table, lifecycle, Window submenu |
