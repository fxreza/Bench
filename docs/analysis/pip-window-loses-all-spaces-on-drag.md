# PIP window stops following Spaces after a mouse drag

Investigation record, 2026-09-08. Root cause identified, not an application bug.
Workaround available today through Snap.

## Summary

On this Mac, a macOS Picture in Picture panel follows the user across Spaces
correctly until it is **moved by a direct mouse drag**. After any such drag the
panel is no longer composited on the all-Spaces layer: during a Space switch it
vanishes for roughly 1 to 2 seconds and reappears only once the switch has
completed. Toggling PIP off and on restores correct behaviour until the next
drag.

The trigger is the drag gesture itself, not the resulting position. Moving the
same window through the **Accessibility API preserves the behaviour**, which is
what makes this actionable: routing PIP moves through Snap avoids the bug
entirely.

This is a macOS defect. It reproduces in Safari with every third party app
quit. It is not specific to IINA and not related to video decoding.

## Environment

| | |
|---|---|
| macOS | 26.6.2 (25G83), Darwin 25.6.0 |
| Hardware | Apple Silicon, built-in Liquid Retina XDR, notch |
| Display | one display, 3456x2234 native, no external display attached |
| Stage Manager | off (`com.apple.WindowManager GloballyEnabled = 0`) |
| Spaces auto-rearrange | off (`com.apple.dock mru-spaces = 0`) |
| Displays have separate Spaces | on (`com.apple.spaces spans-displays = 0`), irrelevant on a single display |
| Reported in | IINA 1.4.4 (168) and IINA 1.5.0-beta1 (170) |
| Also reproduces in | Safari (shares Apple's PIP framework) |

## Symptom

1. Start PIP. Switch Spaces. The panel rides along smoothly, visible throughout
   the transition. Correct.
2. Drag the PIP panel with the mouse. Any distance. Release.
3. Switch Spaces again. The panel disappears at the start of the transition and
   reappears after it finishes, a gap of roughly 1 to 2 seconds.
4. The panel stays broken for every subsequent switch. Deactivating and
   reactivating PIP is the only in-app recovery.

The post-drag behaviour looks like `NSWindowCollectionBehavior.moveToActiveSpace`
(window is pulled to the new Space after the switch) where before the drag it
looked like `.canJoinAllSpaces` (window is drawn on all Spaces, including during
the transition). The working hypothesis is that the WindowServer's drag handling
commits the panel to the Space it was dragged in, the same reassignment that is
correct for an ordinary window and wrong for a PIP panel.

## Isolation

| Variable | Result |
|---|---|
| IINA 1.4.4 vs 1.5.0-beta1 | identical, both affected |
| `hwdec` auto vs auto-copy | no difference |
| Safari PIP (YouTube) | **identical failure** |
| Chrome PIP (YouTube) | different failure, blinks unconditionally, own PIP implementation |
| Bench and Raycast quit | no difference |
| Space switch by three-finger swipe | affected |
| Space switch by Ctrl+Arrow | affected |
| **Resize** the PIP panel by hand | **not affected**, stays sticky |
| Drag away and drag back to the original position | affected, position is irrelevant |
| **Move via Accessibility API** (Snap modifier-drag) | **not affected**, stays sticky |
| Reduce Motion enabled | **worse**, panel is absent on the other Space entirely |

Two entries carry the diagnosis. Resize not breaking it, while a drag that ends
where it started does break it, rules out geometry and window-frame updates and
points at the drag gesture's Space bookkeeping. An AX move changing the same
frame without breaking it confirms the defect lives in the WindowServer's
mouse-drag path, not in the act of repositioning.

Reduce Motion making it worse is consistent: it removes the transition that the
panel was reappearing at the end of, leaving it simply not present.

## Ruled out

- IINA, both stable and beta. Application-level fixes are not available here.
- Video decoding path. `hwdec` has no bearing on window compositing.
- Accessibility-based window managers. Bench (Snap) and Raycast were fully
  quit for the Safari reproduction.
- Stage Manager, multi-display Space handling, Space auto-rearrange. All either
  off or not applicable.
- The Space switching gesture. Trackpad and keyboard behave the same.

## Workaround

**Move PIP windows with Snap's modifier-drag. Never grab the panel body.**
Resizing by hand is safe. This is available today with no code change.

## Possible hardening in Bench, not implemented

1. Have Snap detect a plain mouse drag beginning on a PIP panel and route it
   through the existing AX move path, making the broken gesture unreachable.
   Identifying a PIP panel: owning process plus a floating, resizable,
   title-less panel, or matching against the PIP framework's window subrole.
2. Re-apply the all-Spaces flag after a drag. Cross-process this needs the
   private SkyLight tag API (`SLSSetWindowTags` against the owning connection).
   Believed to work without disabling SIP, **unverified**. Option 1 is cheaper
   and does not touch private API.

## Reporting

Worth a Feedback Assistant report against macOS 26.6.2. The repro is clean:
drag breaks it, resize does not, final position is irrelevant, reproduces in
Safari with no third party software running.

## Related

- `Klip/docs/analysis/menubar-status-item-not-laid-out.md` - the other case on
  this Mac where a correct application was broken by system-level window
  bookkeeping rather than by its own code. Same lesson: when a window is
  registered and interactive but not drawn where it should be, suspect the
  WindowServer's records before the app.
