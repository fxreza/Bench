# Changelog

## 0.3.8 (2026-10-04)

### Fixed

- Shot: on macOS 27 the pointer stayed an arrow after a capture shortcut instead of turning into the crosshair. macOS 27 ignores pointer changes from an app that is not frontmost, and the capture overlay never brings Bench to the front. The crosshair now shows right away, without moving the mouse.
- Shot: the pointer flickered between the hand and the arrow over a drawn object, because two parts of the capture overlay set it on every mouse move.

### Changed

- Shot: over the selected object the pointer is the hand (drag to move it); over any other object it is the arrow (click to select it).
- Shot: with the select tool, empty space inside a fresh capture shows the hand, since dragging there moves the capture area. Once the capture has an object, empty space no longer moves it and shows the arrow; the resize handles and the move button still work.
- Shot: the resize handles of the capture area and the editor's crop box use the macOS window-edge double arrows, diagonal at the corners, instead of the crosshair at the corners.
- Shot: the Freehand pointer is a ring as wide as the stroke with a dot in the middle, and the Highlighter pointer is an I-beam over a block of the highlighter colour as tall as the stroke. Both follow the thickness and the editor's zoom.

## 0.3.7 (2026-09-30)

### Added

- Klip: smart image search. Search now also finds images by what the picture shows, using Apple's MobileCLIP model on this Mac: "woman", "girl", "man at a desk", "red car" or "a place for eating" find matching pictures even when no word is attached to them. Picture matches appear below the ordinary text matches, best match first, a moment after you type, so rows already on screen never move. A screenshot that only contains the word you typed is not treated as a picture of it. Existing images are indexed once in the background after launch; the index stays on this Mac and is not synced. The model adds about 190 MB to the app.

### Fixed

- Klip: the words Klip tags images with now match whole words only, so "man" no longer finds pictures tagged "mango" or "german shepherd". Text inside clips still matches parts of words as before.

## 0.3.6 (2026-09-30)

### Added

- Klip: search finds images by the text inside them. Klip reads the text in every image on its own, in the background and on this Mac, so a screenshot turns up when you search for any word in it. Images already in the history are read once, in the background, starting shortly after launch.
- Klip: search finds images by what they show. Every image is tagged on-device with the things in it (flower, desk, laptop, food, sky and so on), so "flower" or "flowers" finds pictures of flowers, and "desk laptop" or "desk+laptop" finds pictures with both. A `+` joins words only between letters, so "c++" is still searched as typed.
- Klip: "Copy text in image" in the preview pane and "Copy Text" in an image's right-click menu copy the text found in the picture. Long text under an image preview is folded to four lines with Show all.

### Changed

- Klip: the "Extract text from image" button is gone; text is read automatically, so there is nothing to extract by hand.
- Shot: the Freehand tool's icon is now a squiggle instead of a pencil. At toolbar size the pencil looked like a diagonal stroke, almost the same as the Line tool's icon next to it.

## 0.3.5 (2026-09-26)

### Fixed

- Snap: Activate Previous Window (⌥⇥) stopped working on macOS 27. When the previous window was on another desktop, the menu bar switched to its app but you stayed where you were and the window never came forward; macOS 27 no longer follows an activated window to its desktop, not even for its own ⌘⇥. Snap now fronts that exact window and, when it lives on another desktop, slides there with your own "Move left/right a space" shortcut (⌃← / ⌃→ by default, in Keyboard Shortcuts > Mission Control), then keeps the window in front while the desktop settles.
- Snap: ⌥⇥ could get stuck on the same app, or go nowhere at all, after a window was closed; closed windows are now dropped from the list before each switch.
- Snap: pressing ⌥⇥ quickly several times could overshoot to an unrelated desktop or keep returning to the same window. A press made while a desktop slide is still running now waits for it to land, and only the latest press counts, so an even number of quick presses brings you back where you started.
- Snap: ⌥⇥ no longer counts windows macOS brings forward on its own when you arrive on a desktop - a floating window shown on every desktop, or an app's window from another desktop - as the window you were last using.

## 0.3.4 (2026-09-25)

### Fixed

- Klip: double-clicking a clip did nothing on macOS 27. It pastes the clip again, exactly as ↩ does. The double-click is now recognised by the row's own click handling instead of a SwiftUI gesture that macOS 27 no longer delivers there.
- Klip: ⌘C sometimes did nothing, and only the Copy icon worked. While the search field had keyboard focus, which is nearly the whole time the window is open, ⌘C was handed to the search field instead of copying the selected clip, so it copied the query you had typed, or nothing at all. ⌘C and ⌥⌘C now copy the selected clip whenever the search field has focus, and defer to a text field only when you have actually selected text in the preview pane with the mouse. Edit mode is unchanged: ⌘C there still copies the text you are editing.
- Shot: ⌘C sometimes did nothing, and only the Copy button worked. After placing a text label, the label keeps the keyboard until Esc, ⌘↩ or a click outside it, and ⌘C went to the label, copying its text or nothing, instead of the screenshot. ⌘C now copies the screenshot whenever the capture is ready, committing the label first, in both the overlay and the editor window. The Copy, Save and Save As buttons commit a label that is still being typed too, so it is no longer missing from the image they produce. ⌘X, ⌘V, ⌘A and ⌘Z still work inside the label while you type it.
- Klip: deleting several selected clips now behaves the same everywhere. ⌘⌫ and the preview pane's trash icon used to delete only the focused clip, one per press, and the row menu's Delete removed the whole selection with no confirmation; only the preview pane's "Delete N Items…" button asked first. Now any of them deletes the whole selection after one "Delete N clips?" card, shown in the window whether or not the preview pane is open, and Esc cancels it. A single clip still deletes at once, since it goes to the Trash and can be restored.
- Klip: an image, a long text or a rich-text clip was silently dropped when its folder under `~/Library/Application Support/Bench/Klip` had disappeared while Bench was running (an app uninstaller that removes every folder named "Klip" does exactly that). The folders were only created at launch; every writer now recreates its folder on demand, so new clips keep landing on disk and the history, trash and folder indexes are written again too.

## 0.3.3 (2026-09-15)

### Added

- Settings sync through iCloud Drive, under Settings > General > iCloud Sync. Every module's settings, the shortcuts, the module on/off switches, the appearance, Lingo's translation history and its Gemini API key travel between your Macs; only what describes one Mac stays put (device names, sync timestamps, onboarding and import flags, update bookkeeping). Each Mac writes only its own file, `Bench/Settings/devices/<id>/settings.plist`, and for each setting the latest change wins, so nothing is ever overwritten by an older copy. A change made on one Mac shows up live on the other, shortcuts and module switches included. Off by default; separate from Klip's history sync.

### Changed

- Everything Bench keeps in iCloud Drive now lives in one `Bench` folder: `Bench/Klip` for the clipboard history and `Bench/Settings` for the settings. The first sync cycle moves an existing `iCloud Drive/Klip` folder into `Bench/Klip` in place, so already-synced history is neither lost nor copied. A standalone Klip.app still syncing to the old location no longer shares history with Bench.

## 0.3.2 (2026-09-15)

### Added

- Snap: Make Larger (Control+Command+=) and Make Smaller (Control+Command+-), Raycast style. Each press grows or shrinks the window's width and height by the resize step (60 pt by default, in Settings > Snap > Layout), keeps its centre, and pushes it back inside the screen when it would spill over an edge. Make Larger ends at the visible frame, Make Smaller at 100 x 100 or the app's own minimum.
- Snap: Almost Maximize (Control+Command+M), Raycast style. The window fills 90 % of the screen's visible frame, centred, leaving a margin of desktop all round; the percentage is in Settings > Snap > Layout.

### Changed

- Snap: Restore Previous Size now works like Raycast's Restore. Every Snap change (a layout, Make Larger or Smaller, Almost Maximize, a modifier-key move or resize) records the frame the window had just before it, so Restore always goes back one step, whatever the window looked like in between. Restore also records the frame it leaves, so pressing it again flips forward, and repeated presses alternate between the last two states. It used to remember only the first frame Snap ever saw for a window and forget it after one restore.

## 0.3.1 (2026-09-10)

### Added

- Klip: the history window can be dragged around by any part of it that nothing else uses (the title, the gaps around the search field and filter chips, the action bar). Clip rows, the scroll areas and the pane resizers keep their own behaviour.
- Klip: a "Remember the last window position" setting under Settings > Klip > General > Window, off by default. Off, every open puts the window back at its default spot, centred on the screen under the mouse. On, the window reopens where it was last dragged to, nudged back onto the nearest screen if that display has since gone away; switching the setting off clears the saved position.

## 0.3.0 (2026-09-08)

### Fixed

- Klip: icon-only buttons (copy, delete, pin, favorite, lock, extract text, save to disk, sidebar and preview toggles) told their available and disabled states apart with `.secondary`/`.tertiary` opacity, which read as too faint in both light and dark mode to make the glyph out. They now use weight together with a fixed `Color.primary` opacity: bold and near-full opacity when available, regular weight and dimmer when disabled. Disabled preview-pane buttons switch to a no-op action instead of `.disabled()`, which on macOS 26 dimmed the label a second time on top of the new color and made the glyph unreadable.

## 0.2.1 (2026-09-08)

### Added

- Tap: hold fn and click normally for a middle click, on by default and independent of the three-finger triggers, so any combination of the three can be on. It counts no fingers, so it works whenever the trackpad gesture will not; fn is the one modifier a click has spare, with Command, Shift, Option and Control all meaning something already.
- Tap: a three-finger click that the trackpad driver reports as a two-finger secondary click is converted too, instead of passing through and opening a context menu.

### Fixed

- Bench no longer quits at launch on any Mac other than the one it was built on. Piko looked up its now-playing resources through SwiftPM's generated `Bundle.module`, which trapped when neither the app root nor the build machine's build directory held the bundle; the lookup now returns nil and only turns now playing off.

## 0.2.0 (2026-09-08)

### Added

- Tap: a new module that turns three fingers on the trackpad into the middle mouse button, by clicking with three fingers down, by a quick three-finger tap, or both (Settings > Tap). It replaces the last BetterTouchTool trigger. Palm rejection runs on the raw touch stream: hovering contacts, palms and the base of the thumb are dropped, and only a tight three-finger cluster of one hand counts, so a hand resting elsewhere on the pad neither cancels the gesture nor fires it by accident.
- Snap: hold Shift+Option and move the mouse to move the window under the pointer, or Shift+Control to resize it, without clicking. Modifiers, drag threshold and bring-to-front are in Settings > Snap.
- Snap: three Open App shortcuts. Pick an app in Settings > Snap, then bind a key in the shortcut list.
- Shot: files are named after the app that was captured, for example "Safari 2026-09-08 at 14.03.10.png" (Settings > Shot > General, on by default), and saved files get a Finder "Where from" entry naming that app.
- Klip: a clip copied from a screenshot is credited to the app that was captured instead of Bench.
- General settings: Dock gaps. Two steppers add or remove macOS's own invisible Dock spacer tiles, full and half width, to drag between icons.
- General settings: menu bar divider lines, thin inert items to Command-drag between menu bar icons to group them.

### Changed

- Snap: New Terminal Window and Open Downloads in Finder moved from Control+Command+T and Command+E to Control+Option+T and Control+Option+E, out of the way of the window-layout shortcuts and the system Command+E.

### Fixed

- Klip: a screenshot or any other clip taken shortly after pasting from the history was sometimes dropped. The "ignore my own write" flag now expires after 1.5 seconds.
- Klip: Shift+Up and Shift+Down in the history list keep a fixed anchor and shrink the selection again when walking back, like Finder and Mail.

## 0.1.0 (2026-09-07)

### Fixed

- Piko no longer slows the menu bar. Its notch used a system-wide mouse-moved event monitor that throttled menu highlighting while any menu was open; it now samples the pointer on a timer with no event tap, so menus track the pointer at full speed.

### Added

- Bench: one menu bar app hosting five modules - Shot (screenshots), Klip (clipboard history), Lingo (translation), Snap (window management) and Piko (Dynamic Island for the notch).
- Snap: window layouts, restore, previous window and the two scripts, replacing the BetterTouchTool triggers. See docs/snap.md.
- Status menu with a section per module, Settings, Permissions, Check for Updates, Launch at Login and the running version.
- Settings window: General, Shortcuts, Permissions and About, plus one pane per module with its own on/off switch. A module that is off holds no shortcuts, timers or windows.
- One shortcut store for the whole app: every module's global shortcuts in one list, rebindable, with conflicts checked across modules and macOS refusals reported on the row.
- Appearance: an app-wide accent color and Light/Dark/System choice.
- In-app updater: checks GitHub releases once a day, verifies that a downloaded build carries Bench's bundle identifier and the same signing identity as the running copy before installing, and shows what changed after it relaunches.
- First launch registers Launch at Login and opens Permissions when Accessibility or Screen Recording is missing.
- A one-time warning when Klip, Snapper, Transi or Piko are still running, since they register the same shortcuts Bench does.
- Copy-only import of the standalone apps' settings and data on first launch; Klip, Snapper, Transi and Piko are never written to.
