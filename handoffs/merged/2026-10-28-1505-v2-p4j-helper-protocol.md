# v2.1 Phase 4j: helper protocol, codec and XPC server/client (core)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-2100-v2-p4j-helper-protocol.md

## What the user asked
Build brief 4j of `docs/v2/ADR-0008-background-helper.md`. That means:
- `HelperProtocol.swift`, `HelperCodec.swift` and `HelperXPC.swift` in `Background/`;
- `Codable` on the tick types;
- `HelperProtocolTests` and `HelperXPCTests`.

Nothing registers or launches a helper yet; that's 4k.

## What changed
Everything in the brief is built and passing. One thing changed from the ADR, by ruling: a
1,000-process tick can't encode and decode in the ADR's 5 ms. Jarvis chose (a): keep
binary-plist `Codable`, with a bound of ≤ 80 ms in release and debug (see the answered question
below).

- **`HelperProtocol.swift`** holds the wire types:
  - `HelperEnvelope`, `BackgroundSettings` and `HelperHello`;
  - `HelperControlRequest` and `HelperControlReply` (every row of ADR §2);
  - `HelperReadRequest` and `HelperReadReply` (three reads plus `.notRunning`);
  - `HelperEvent` (`.tick`, `.summary`), `HelperFailure`, and `LiveTickPayload = LiveTick`;
  - the constants: `protocolVersion = 1`, both Mach service names, and the three requirement
    strings for the app, the CLI and the helper.
  - The read cases are encoded under `read.`-prefixed keys, so no control request can decode as
    a read, and no read can decode as a control request. Both directions are tested.
- **`HelperCodec.swift`** encodes and decodes binary plists, strictly:
  - the 8 MB cap applies on both sides, and on decode it's checked before any parsing;
  - a message must start with `bplist00`, so XML and JSON are refused;
  - the protocol version is read before the body, so another version is always a
    `.versionMismatch` and never "malformed";
  - truncated data, an unknown case or a missing field becomes `.malformed(path)`. The error
    names where decoding stopped, never the payload.
- **`HelperXPC.swift`** has the XPC layer:
  - **Protocols:** the `@objc` `HelperControlXPC`, `HelperReadXPC` and `HelperEventsXPC`.
  - **`HelperListenerDelegate`:** 4k keeps one per listener, because `delegate` is weak.
  - **`HelperServer`:** maps requests onto `BackgroundMonitor` and `HistoryStore`, and owns the
    orphan timer. Reads answer `.notRunning` unless the helper is configured, sampling and the
    MCP switch is on.
  - **`HelperClient`:** see below.
  - **`HelperReadClient`:** the CLI side, with a 5 s timeout.
- **How the server handles messages:**
  - It answers each connection's messages one at a time, in arrival order, through a queue.
  - Messages beyond 64 queued are answered `.busy`.
- **`HelperClient` (the app side):**
  - `connect()` makes one attempt.
  - When an established connection is lost, it retries after 1, 2 and 5 s, then every 10 s.
  - Each reconnect replays `hello`, Pause, `configure`, the viewer and the subscription.
  - Three refusals in a row (another build or version) end the retries with `.refused`, which
    4k can use to fall back to in-app mode.
- **`Codable` conformance only**, in these shared files:
  - `Live/LiveMonitor.swift`: `LiveTick`, `LiveHistory.Window`;
  - `Projects/ProjectBreakdown.swift`: `ProjectUsage`, `ProjectUsage.Bucket`, `ProjectBreakdown`;
  - `Projects/ProjectAttributor.swift`, **not in the brief's list**: `ProjectMapping` (for
    `BackgroundSettings`) and `ContainerAttribution` (inside `ProjectBreakdown`);
  - `Rules/AlertPolicy.swift`: `AlertRule`, `AlertRule.Kind`, `AlertConfiguration`, `Alert` and
    `Alert.Watch`, plus an `AlertRule.init(from:)` that decodes through `init`. A decoded rule is
    then clamped as a built one is (`off` ≤ `on`, no negative times). This is tested;
  - `History/HistoryModel.swift`: `HistoryPoint`, `HistoryProjectPoint`, `TimelineEvent`,
    `TimelineEvent.Kind`, `HistoryWindow`.
  - `BackgroundMonitor.Subscription` gets its `Codable` in an extension in
    `HelperProtocol.swift`, so `BackgroundMonitor.swift` is untouched.

## Files
- Sources/HeatLensCore/Background/HelperProtocol.swift — created
- Sources/HeatLensCore/Background/HelperCodec.swift — created
- Sources/HeatLensCore/Background/HelperXPC.swift — created
- Sources/HeatLensCore/Live/LiveMonitor.swift — modified (conformance only)
- Sources/HeatLensCore/Projects/ProjectBreakdown.swift — modified (conformance only)
- Sources/HeatLensCore/Projects/ProjectAttributor.swift — modified (conformance only)
- Sources/HeatLensCore/Rules/AlertPolicy.swift — modified (conformance, plus `AlertRule.init(from:)`)
- Sources/HeatLensCore/History/HistoryModel.swift — modified (conformance only)
- Tests/HeatLensCoreTests/HelperProtocolTests.swift — created
- Tests/HeatLensCoreTests/HelperXPCTests.swift — created
- handoffs/2026-10-28-1505-v2-p4j-helper-protocol.md — created

## Checks run
- **`swift build --build-tests`:** builds in Swift 6 mode with no warnings or errors.
- **`scripts/with-timeout.sh 600 swift test --filter "HelperProtocol|HelperXPC"`, three runs in
  a row after the ruling:** 24 tests in 2 suites passed each time (0.50 s, 0.50 s, 0.48 s).
  `tickCost` measured 59.6, 59.9 and 56.2 ms of CPU against the 80 ms bound.
  - **`HelperXPCTests`:** 11 tests, end to end over `NSXPCListener.anonymous()`. They cover:
    - `hello`, `configure` and `setViewer`;
    - `.full` gets ticks and `.summary` doesn't (alerts arrive in summaries);
    - reads answer `.notRunning` when unconfigured, with the switch off, or when paused;
    - `limit` outside 1...50 is refused, and a read never changes the mode;
    - six control envelopes sent to the read service are refused, and nothing changes;
    - a build mismatch gets `.restartRequired` and the helper exits;
    - a protocol v2 envelope is refused as a mismatch and the helper exits;
    - nothing but `hello` is answered before `hello`, and junk gets an error reply;
    - the orphan pause with an injected clock: still sampling at 3,599 s, paused at 3,601 s,
      and resumed by the next `hello`;
    - `pauseUntilAppOpens` leaves the helper idle with no orphan clock;
    - after a dropped connection the client reconnects and replays the viewer, ticks and status;
    - `recordActions` lands in the store, with `savedActions`, `historySize`, `historyWindow`,
      retention and Delete history all going through the helper;
    - `shutdown` stops sampling and exits, and the client doesn't reconnect.
  - **`HelperProtocolTests`:** 13 tests. They cover:
    - round trips of every request, reply, push and failure;
    - oversize on both sides; truncated, empty, JSON, XML and junk input;
    - the wrong version (0, 2, -1, `Int.max`) and an unknown case;
    - the two channels not overlapping, and the alert-rule clamp;
    - `tickCost`;
    - the §3 grep, which also forbids `UNUserNotificationCenter`, `BatchStop` and
      `ProcessTerminator` and scans `Sources/heatlens-helper/` once 4k creates it;
    - no network code;
    - the ad-hoc runner failing all three requirements (`SecCodeCopySelf` plus
      `SecCodeCheckValidity`).
- **Release timing works with `@testable`:**
  `swift build -c release --build-tests -Xswiftc -enable-testing` (about 50 s once cached), then
  `swift test -c release --skip-build -Xswiftc -enable-testing --filter HelperProtocol`. All 13
  tests pass; `tickCost` measured 55.4 ms of CPU.
- **Full suite once:**
  `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`. 450 tests in
  65 suites passed; `tickCost` measured 60.6 ms of CPU under load. That tree includes the 4c
  worker's uncommitted `App/` edits.
  - **The first run failed once, and I changed how the test measures.** That run measured
    88 ms, because under the parallel full suite the wall clock also counts time spent waiting
    for a core.
  - **What I changed:** `tickCost` now measures the test thread's CPU time
    (`CLOCK_THREAD_CPUTIME_ID`). The budget is about CPU, and the loop never awaits, so it stays
    on one thread. The bound is still the ruled 80 ms.
- **The Done-when grep**
  (`kill\(|requestStop|forceQuit|ContainerStopper|StopLedger|URLSession|import Network` over
  `Sources/HeatLensCore/Background/`) prints nothing.
- **`scripts/run-app.sh --build-only`:** built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- **`handoffs/bin/jarvis leftovers --mine`:** nothing running.
- **Not checked:**
  - anything with a real Mach service, launchd or code-signing requirement on a listener (4k,
    on a build Jarvis signs);
  - the CLI or app using these clients (4k, 4l);
  - real-timer backoff (the tests scale 1 s of wait to 1 ms).

## Processes left running
none

## Questions for the user
None open. Question 1 (the tick encode bound) was answered (a): keep binary-plist `Codable`,
≤ 80 ms in release and debug, no custom format.

## Notes for Jarvis
- **Measured numbers, for ADR-0008 §6 and PERFORMANCE §2.9.** The synthetic tick has:
  - 1,000 processes, 200 groups, both top lists with 150-tick trends for 24 processes;
  - 10 containers, 3 project rows, and a session timeline of 150 points, 1,200 project points
    and 200 events.
  - **On the wire:** 358,536 bytes as a binary plist.
  - **Release, best of 7, wall time:**
    - encode 24.3 ms, decode 31.0 ms, together 54–56 ms;
    - JSON instead: 15.2 + 14.1 ≈ 29 ms;
    - without the process list: about 31 ms; without the process list and the timeline:
      about 21 ms;
    - 800 processes: 49 ms; 200 processes: 27 ms.
  - **`tickCost` as CPU time of the test thread:** 55.4 ms in release; 56–60 ms in debug (debug is
    barely slower because Foundation's coders are prebuilt); 60.6 ms under the parallel full
    suite.
  - **What it costs:** paid only for `.full` pushes, while the Live view is visible, about
    25 ms in the helper and 30 ms in the app per tick. That's ≈ 1.1% of a core at the 5 s
    interval and ≈ 2.7% at 2 s, which is over ADR-0003's 2% Live budget at 2 s. A closed panel
    gets `.summary` pushes of a few KB.
- **Shared-file edits:**
  - conformance only, in the four files the brief named, plus
    `Projects/ProjectAttributor.swift`, which `BackgroundSettings` and `ProjectBreakdown` need;
  - `AlertPolicy.swift` also gains a decoding `init`.
  - `BackgroundMonitor.swift`, `App/`, `Package.swift`, `project.yml`, the CLI, `Safety/`,
    `Docker/` and docs are untouched.
- **Places I went past the ADR's letter (none of it changes the design):**
  - **`hello` first:** every request but `hello` is refused until that connection's `hello`.
  - **Version mismatch exits:** a protocol-version mismatch on the control service makes the
    helper exit, as a build mismatch does, so launchd starts the bundle's own binary. The client
    gives up after three refusals in a row.
  - **Pause is replayed:** `HelperClient` also replays Pause on reconnect, so a helper crash
    doesn't undo the user's Pause.
  - **Light configure:** `configure` doesn't restart the session when only alerts, the MCP
    switch or retention changed; it uses `setAlerts`. An identical replay after a reconnect
    therefore keeps the timeline. A reopened history store does restart the session.
  - **History failures:** a `configure` whose history can't be opened still applies. It replies
    `.failure(.history(…))`, and the client's replay ignores that failure.
  - **The reason a paused helper shows:** an orphan pause, `pauseUntilAppOpens` or `shutdown`
    shows `.paused(.user)`, because `PauseReason` has no "until the app opens" case and
    `BackgroundMonitor.swift` was off limits. No app is connected then, and reads say
    `.notRunning`, so nobody sees it. The next `hello` resumes.
  - **Delete history:** as in the app today, a running session stops saving until the next
    `configure`.
  - **Exit timing:** `onExit` fires `HelperServer.exitGrace` (1 s) after the reply, so the reply
    can leave first.
  - **Idle check:** `isIdle()` is there for 4k's "exit after 60 s idle".
- **For 4k:**
  - `HelperClient.helper(appBuild:)` and `HelperReadClient.helper(build:)` set
    `setCodeSigningRequirement(HelperProtocol.helperRequirement)`.
  - The listeners must call `setConnectionCodeSigningRequirement`, with `appRequirement` for
    control and `cliRequirement` for read.
  - A 24-hour `historyWindow` fits well under the 8 MB cap. A 30-day window could exceed it and
    would get `.failure(.tooLarge)`, but the app never asks for more than 24 hours.
- **Suggested commit:** `feat(v2.1): Phase 4j — helper protocol (versioned
  binary-plist envelopes, 8 MB cap, read./control channels), HelperServer/HelperClient/
  HelperReadClient over XPC with hello-first, 1/2/5/10 s reconnect + replay and the 1-hour
  orphan pause; Codable tick types; tick encode bound 80 ms by ruling`
