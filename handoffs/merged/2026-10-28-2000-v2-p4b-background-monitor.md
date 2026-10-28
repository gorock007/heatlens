# v2 Phase 4b: BackgroundMonitor (core)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-2000-v2-p4b-background-monitor.md

## What the user asked
Build brief 4b of `docs/v2/ADR-0008-background-helper.md`: a `public actor BackgroundMonitor` in
`Sources/HeatLensCore/Background/` that owns one `LiveMonitor`. It has the listed API, the
keepWatching rules, a ring of the 50 most recent alerts, and `BackgroundMonitorTests`. No hook in
`LiveMonitor` was needed, and there were no questions: the spec held together.

## What changed
Nothing in the app changes yet; 4c wires this in.

- **`BackgroundMonitor`**: one Live session for the app. It always gives `LiveMonitor`
  `sampling: .adaptive` and `autoPauseAfter: nil`, and makes the 15-minute rule itself with an
  injected clock.
  - **Keep watching off**: today's Live. It samples only while a viewer is attached, at the
    viewer's 2/5/10 s interval. The viewer detaching stops sampling, and 15 minutes after the
    session started it pauses (`.autoPaused`).
  - **Keep watching on**: `configure` starts background sampling at once, at the policy's
    30/60/5/10/120 s. A viewer attaching gets its interval and an immediate tick (the 4a note
    about `refreshNow`). Detaching, or 15 minutes of foreground, returns to the policy's
    cadence. Nothing stops sampling except Pause, a failure, the switch going off, or the app
    quitting.
  - **API:**
    - `configure(_:keepWatching:)`, `viewerAttached(interval:)` (also used to change the
      interval), `viewerDetached()`, `pause()`, `resume()`, `refreshNow()`;
    - `subscribe(.full / .summary) -> AsyncStream<BackgroundEvent>`;
    - `status`, `recentAlerts(since:)`, `explanations`, `isSampling`;
    - one addition the brief didn't list: `setAlerts(_:)` (below).
  - **`BackgroundEvent`** is `.tick` (to `.full` only), `.status`, `.alerts([Alert])` (to every
    subscriber) and `.stopped(PauseReason)`.
  - **`BackgroundStatus`** (Codable, for 4j) holds:
    - `mode`: `.paused(reason)`, `.foreground(interval)` or `.background`;
    - the current `interval` and `reason`;
    - `since`, when the mode last changed;
    - `lastTickAt` and `lastTickCost`.
  - **`PauseReason`**:
    - `notConfigured` and `notWatching` are not sticky;
    - `user`, `autoPaused` and `failed(String)` are sticky: only `resume()` clears them;
    - a viewer attaching does not undo a pause.
  - **Every subscription cancelled** detaches the viewer. A foreground-only session (Keep
    watching off) stops; a background session goes on.
  - **Calls into `LiveMonitor` run one at a time**, in order, through a task chain. A quick
    pause/resume or a settings restart can't start two sessions or leave none. Each public
    method returns once its `LiveMonitor` calls are done.
  - **`AlertEvaluator`** stays `LiveMonitor`'s, which lives as long as this actor. Cooldowns
    therefore hold across pause, resume, mode changes and restarts (tested).
  - **The monitor never signals.** A test greps `Background/` for `kill(`, `requestStop`,
    `forceQuit`, `ContainerStopper`, `StopLedger`, `"POST `, `URLSession` and `import Network`.

## Files
- Sources/HeatLensCore/Background/BackgroundMonitor.swift — created
- Tests/HeatLensCoreTests/BackgroundMonitorTests.swift — created
- handoffs/2026-10-28-2000-v2-p4b-background-monitor.md — created

## Checks run
- `swift build`: Build complete, no warnings in the new file.
- `scripts/with-timeout.sh 600 swift test --filter "BackgroundMonitor|LiveMonitor"`, three runs
  in a row: 34 tests in 2 suites passed each time (1.25 s, 1.24 s, 1.24 s). That is 12 new
  BackgroundMonitor tests plus the existing LiveMonitor tests, which are unchanged.
- `grep -rnE "kill\(|requestStop|forceQuit|ContainerStopper|StopLedger" Sources/HeatLensCore/Background/`
  printed nothing.
- Full suite once:
  `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test` gave 426
  tests in 63 suites, all passed. That tree included the 4f worker's uncommitted edits.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- `handoffs/bin/jarvis leftovers --mine`: nothing running.
- **Not checked:**
  - anything in the app (4c wires it in);
  - real timers (the tests scale 1 s of wait to 1 ms);
  - a real sleep/wake;
  - CPU budgets: the cadence is 4a's `SamplingPolicy`, which PERFORMANCE §2.9 measured.

## Processes left running
none

## Questions for the user
None.

## Notes for Jarvis
- **No shared files touched**, and no `LiveMonitor` hook was needed: everything goes through
  `start`, `stop`, `setViewer`, `refreshNow` and `setAlerts`.
- **For the 4c worker (put this in its brief):**
  - **"Start live" must call `resume()` and then `viewerAttached(interval:)`.**
    `viewerAttached` alone deliberately doesn't undo Pause, so a panel that attaches on open
    can't override the user's Pause ("paused until Resume or the next launch").
  - Pause → `pause()`. Panel close or Scan → `viewerDetached()`. The picker →
    `viewerAttached(interval:)` again (it ticks at once, as `setInterval` does today).
  - Alert settings → `setAlerts(_:)`, which doesn't restart the session.
  - Every other settings change → `configure(_:keepWatching:)`. On a running session that
    **restarts** it, as closing Settings does today, which drops the in-memory timeline,
    explanations and incident state.
  - `LiveAlertService` should subscribe `.summary` and post from `.alerts`. `LiveModel` should
    subscribe `.full` while the Live view shows.
- **Places where I read the spec loosely:**
  - Subscriber buffer is `.bufferingNewest(8)`, not 2. A tick sends up to three events (tick,
    alerts, status), and with 2 a slow subscriber could lose an `.alerts` event, which is a
    missed notification. Old ticks are still dropped first.
  - **Status right after a mode change.** The status says what the policy waits now. Right
    after a viewer leaves, the last tick still says "viewer", so the background interval is
    worked out from that tick's power and incident until the next tick confirms it.
  - **When the 15 minutes start.** They count from the foreground session's start, or from the
    viewer attaching. A settings restart starts them again, as today's restart-on-Settings-close
    does.
- **Suggested commit:** `feat(v2): Phase 4b — BackgroundMonitor (foreground/background/paused
  modes over one LiveMonitor, .full/.summary subscriptions, recent-alerts ring of 50, status;
  15-min fallback or auto-pause)`
