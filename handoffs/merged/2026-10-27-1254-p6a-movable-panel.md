# Phase 6a: movable HeatLens panel, Escape closes it, "Copied" labels reset
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1235-p6a-movable-panel.md
## What the user asked
Make the panel movable anywhere, keep a moved panel open beside other apps, close it with
Escape, reopen fresh under the icon, and have "Copied" labels revert after about 2 seconds.

## What changed
- `MenuBarExtra(.window)` is replaced by an AppKit `NSStatusItem` (same `thermometer.medium`
  symbol) plus a borderless, non-activating `NSPanel` hosting the unchanged `PopoverView`
  (`App/StatusPanel.swift`), set up from an `@NSApplicationDelegateAdaptor` that owns the single
  `ScanModel` for the app's lifetime. The panel keeps a rounded `.popover` vibrancy look.
- Clicking the icon opens the panel under it and clicking again closes it. An unmoved panel
  closes when the user clicks another app. Dragging the "HeatLens" title or any empty
  background moves it. A drag is detected with `windowWillMove`, which only user drags send.
  A moved panel is detached: it's `.floating` and stays open until Escape or the icon closes
  it. The next open is under the icon and attached again; no position is remembered.
- Escape is handled in the panel's `sendEvent`, so it closes the panel from any view
  (settings text fields included). A sheet is its own window: Escape there closes only the
  sheet. SwiftUI's sheet already does that.
- The panel follows content height changes, keeping its top edge under the icon or where it
  was dropped. It's clamped inside the screen's visible frame.
- "Copied" / "Copied PID" / "Copied command" revert about 2 s after the click. This uses
  `.resetsAfterCopy($flag)`, a `.task(id:)` with one `Task.sleep` in `App/FindingCard.swift`,
  applied to the existing `@State` flags. No repeating timer.
- The SwiftUI `App` still needs a scene. It uses a `MenuBarExtra` with
  `isInserted: .constant(false)`. A `Settings { EmptyView() }` placeholder answered ⌘, with an
  empty window, which I caught and replaced.
- `PopoverView` change: one line, `.allowsHitTesting(false)` on the header title. SwiftUI
  `Text` swallows mouse-downs, so without it only truly empty space started a drag.

Behavior decisions worth knowing:
- **Escape while scanning** closes the panel and leaves the scan running. The scanning
  view's Cancel had `.cancelAction`, so Escape used to cancel the scan; rule 4 says Escape
  closes the panel. Reopening shows the progress, and Cancel still stops the scan. Verified.
- Dragging works on the title and empty background, not on other text or inside the
  scrolling results. Those take the press as before.
- Settings open/closed state survives a close, the same as the old `PopoverView` `@State`.

## Files
- App/StatusPanel.swift — created
- App/HeatLensApp.swift — modified
- App/PopoverView.swift — modified
- App/FindingCard.swift — modified
- App/ProcessDetailView.swift — modified
- docs/CLICKTHROUGH.md — modified
- handoffs/2026-10-27-1254-p6a-movable-panel.md — created

## Checks run
- `swift build`: Build complete. `swift test`: 99 tests in 18 suites passed.
  `scripts/run-app.sh --build-only`: built, with no errors.
- I drove the app myself. The status item was opened with a System Events press on my
  build's own menu-bar item (found by PID). A menu-bar manager covers that x position on
  this Mac, so **a physical click on the icon was not tested**. Other input was
  CoreGraphics mouse and key events. Panel frames were read from System Events.
  Screenshots are in
  `/private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/9651e368-c2d7-43a5-a315-91069bd00a62/scratchpad/`.
  1. Open under icon / icon closes: frame `718,37` centered under the icon at `856–880`;
     a second press closes it, including when detached (`01-open.png`).
  2. Drag: the title and empty background move the panel, including on the second display
     (`02-detached.png`, `07…`).
  3. Click another app: an unmoved panel closes; a moved one stays open and Arc stays
     frontmost (`02-detached.png`).
  4. Escape closes the panel, attached or detached, and from Settings. With the stop sheet
     up, Escape closes only the sheet, attached (`23`/`24-attached-sheet*.png`) and
     detached (`17-sheet.png`, `18-sheet-esc.png`). A click away after the sheet still
     closes an attached panel.
  5. Reopen after a close starts under the icon, attached, and closes on click-away.
  6. Copied → reverts: `08-copied.png` / `09-copy-reset.png` (card) and
     `13-detail-copied.png` / `14-detail-reset.png` (detail view).
  7. ⌘Q from the panel quits. ⌘, does nothing. There is one status item. Idle with the
     panel closed: 0.0% CPU and CPU time unchanged (0:00.94) over 30 s. The panel grew past
     the bottom of the screen and was clamped inside it (`28-grown-on-screen.png`). The
     scan continued after Escape (`29-scan-continues.png`). The shared model kept results
     across close/reopen.
- I ran the sheet and copy checks on a temporary local build wired to
  `FixtureScanService`/`FixtureStopService`. This Mac's real scan had no stop-eligible
  leftover. The source was restored: `App/HeatLensApp.swift` uses `PipelineScanService` /
  `TerminatorStopService`. I verified that with grep and with the final builds. Send SIGTERM
  was never clicked.
- Not checked: a physical click on the menu-bar icon (see above); behavior in full-screen
  Spaces; VoiceOver.
- Two things to know about the session:
  - One gear click closed the panel once right after a ⌘, test. It didn't reproduce in 5
    later tries.
  - Before the sheet fix, two Escape key presses I sent landed in whichever Superset
    terminal was focused on the external display, because the panel had already closed.
    After that, my script sent Escape only after confirming the panel was open. The copy
    test changed the clipboard; I restored its previous plain-text contents.
- The user's own `/Applications/HeatLens.app` (PID 70969) was running throughout. I didn't
  touch it. My builds were started with `open -n` and quit with ⌘Q.

## Processes left running
none

## Notes for Jarvis
- No shared files touched (`project.yml` and `App/Info.plist` unchanged; the new file is
  picked up by the `App/` glob).
- With `/Applications/HeatLens.app` running, `scripts/run-app.sh`'s plain `open` may
  activate that copy instead of the Debug build. I launched with `open -n <app>`.
- Suggested commit: `feat(app): movable status panel with Escape to close; Copied labels reset after 2 s (Phase 6a)`
