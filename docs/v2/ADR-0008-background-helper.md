# ADR-0008: Background monitoring: in the app for v2.0, a LaunchAgent helper over XPC for v2.1

- **Status:** Accepted for Phase 4 (2026-10-28; owner rulings of the same day in
  `handoffs/2026-10-28-1800-v2-p4-design.md`)
- **Context:** PRD-v2 §6 Phase 4 ("signed macOS background helper/LaunchAgent, opt-in launch at
  login, clear pause/quit/uninstall behaviour"; "optional Jarvis integration via an explicitly
  enabled, authenticated local protocol"), §8 (least privilege, no root), §9 (budgets). ADR-0003
  (Live runs only while the user watches; no local server; "Phase 4's background helper … would
  speak to the UI over XPC, never TCP. That needs a new ADR"). ADR-0005 (history),
  ADR-0006 "Revisit when" (signalling and the ledger), [PHASE-3-REPORT](PHASE-3-REPORT.md).
- **The problem it solves:** alerts (3c), explanations (3b) and history (2c) only exist while Live
  runs, and Live stops when the panel closes (`AppDelegate`: `statusPanel.onClose = { live.stop() }`).
  So HeatLens can't warn about a hot Mac nobody is looking at, which is when a warning matters most.
- **Companion plan:** [PHASE-4-PLAN.md](PHASE-4-PLAN.md) covers adaptive sampling, watchlists,
  incident export, logs, crash recovery and the MCP tools, with every Phase 4 brief in order.

## Owner decisions (2026-10-28)

These are the rulings this ADR depends on. All nine are listed in PHASE-4-PLAN.

1. **v2.0 ships in-app background monitoring**: "Keep watching in the background", opt-in and off by
   default, built on a shared core `BackgroundMonitor`. **The LaunchAgent + XPC helper ships in
   v2.1** on the same core.
2. **Focus:** background alerts respect Focus. They use the default `.active` interruption level,
   never Time Sensitive.
3. **Quit:** "Quit HeatLens" pauses background monitoring until the app opens again. **The helper
   never posts notifications.** It hands alerts to the app, which posts them. Alerts raised while
   the app was closed are listed when it next opens. Turning the switch off unregisters the helper.
7. **MCP** read-only tools (`live_status`, `recent_alerts`, `explanations`) sit behind an off
   switch. They answer only while the helper is sampling, the helper checks the CLI's code
   signature on every connection, and a CLI connection never starts sampling. They land with the
   helper (v2.1).
8. **Battery:** idle every 30 s on power and 60 s on battery; incident every 5 s and 10 s; Low
   Power Mode every 120 s and never fast.

## Decision

### 1. One core, two hosts

`BackgroundMonitor` is a new actor in `Sources/HeatLensCore/Background/`. It owns the one
`LiveMonitor` session and decides its cadence through the `SamplingPolicy` in PHASE-4-PLAN 4a.
That includes "a viewer is looking", which uses the user's 2/5/10 s interval. It feeds
subscribers. Everything that already runs inside `LiveMonitor.run` keeps running there unchanged:
`ProvenanceResolver`, `ProjectAttributor`, `TimelineDetector`, `ConcurrencyRules`,
`AlertEvaluator`, the watchlist evaluator (4f), and `HistoryRecorder` into `HistoryStore` when
Keep history is on. `BackgroundMonitor` adds no analysis of its own. It adds:

- **Modes:** `paused`, `foreground(interval)` (panel open on Live) and `background` (policy
  cadence, no auto-pause). The 15-minute auto-pause stays for foreground sessions while the
  switch is off. With the switch on, a forgotten panel drops back to background cadence after 15
  minutes instead of pausing.
- **Subscriptions:** `.full` delivers every `LiveTick`, while the Live view is showing. `.summary`
  delivers status, new alerts and current explanations, which is all a closed panel needs.
  In-process both are plain values. Over XPC (v2.1) the difference is the payload size.
- **A recent-alerts ring:** the newest 50 alerts, in memory only, so alerts raised while no app was
  attached can be listed later (owner decision 3).
- **Status:** mode, current interval and why (idle, incident, battery, Low Power Mode, viewer),
  when it started, and the last tick's time and cost.

| | v2.0: in the app | v2.1: LaunchAgent helper |
|---|---|---|
| Where `BackgroundMonitor` lives | The app process, next to `LiveModel` | `Contents/Helpers/heatlens-helper`, started on demand by launchd |
| How the UI gets ticks | An `AsyncStream` subscription | XPC push from the helper to the app (§2) |
| Who posts notifications | The app (`LiveAlertService`) | The app, the same code; the helper never does |
| Who owns `history.sqlite` | The app | The helper while it runs; the app sends action records and Delete history to it (§3) |
| Survives an app crash | No | Yes, for up to 1 hour without an app (§4) |
| MCP read access | No (no Mach service) | Yes, behind the switch (PHASE-4-PLAN 4l) |

v2.1 keeps one Settings switch. If the helper can't be registered (an ad-hoc build, approval
refused in System Settings, or `SMAppService` failing), HeatLens falls back to the v2.0 in-app
mode and Settings shows why in one line.

### 2. IPC (v2.1): XPC Mach services, typed and versioned Codable messages, no listener on any port

ADR-0003's "no local server" holds. There's no TCP or UDP port and no Unix socket file. The helper
publishes two launchd Mach services, and the **type** of each one is its boundary:

| Mach service | Exported protocol | Who may connect (code-signing requirement, checked by the system per connection) |
|---|---|---|
| `dev.heatlens.HeatLens.helper` | `HelperControlXPC` | `anchor apple generic and identifier "dev.heatlens.HeatLens" and certificate leaf[subject.OU] = "9PXJ82UU32"` |
| `dev.heatlens.HeatLens.helper.read` | `HelperReadXPC` | the same, with `identifier "dev.heatlens.heatlens"` (the CLI, signed with that identifier by `scripts/release.sh`) |

- **Transport:** `NSXPCListener(machServiceName:)` with
  [`setConnectionCodeSigningRequirement(_:)`](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))
  (macOS 13+, inside our macOS 14 target). On the client side,
  [`NSXPCConnection.setCodeSigningRequirement(_:)`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
  checks the helper against `identifier "dev.heatlens.heatlens-helper"` and the same anchor and
  team. The system checks the requirement against the connection's audit token, not a PID, so a
  PID-reuse race can't pass it. The newer Swift `XPCSession` peer-requirement API needs a newer
  macOS than the target, so we don't use it.
- **One method per direction.** Each `@objc` protocol has a single method that carries `Data`:
  `func handle(_ request: Data, reply: @escaping (Data) -> Void)`. The app also exports
  `HelperEventsXPC.receive(_ event: Data)` for pushes. Inside the `Data` is a Swift `Codable`
  envelope, encoded as a binary property list:

  ```swift
  struct HelperEnvelope<Body: Codable>: Codable {
      let protocolVersion: Int   // major; a mismatch is refused on both sides with a clear message
      let build: String          // CFBundleVersion of the sender
      let body: Body
  }
  ```

  NSSecureCoding sees only `NSData`. Payloads over 8 MB are refused before decoding, and an unknown
  case is an error reply, never a crash.
- **Control messages** (`HelperControlRequest`, app → helper), each with a typed reply:

  | Request | Reply / effect |
  |---|---|
  | `hello(appBuild)` | `helperBuild`, `protocolVersion`, `BackgroundStatus`. A build different from the app's → `.restartRequired`, and the helper exits after replying (§5) |
  | `configure(BackgroundSettings)` | All the settings the core needs: sources, workload rules, project mappings, `AlertConfiguration`, watchlists, Keep history and retention, the MCP read switch. The helper keeps nothing on disk; the app sends this on every connect and on every Settings change |
  | `setViewer(attached:interval:)` | foreground or background cadence |
  | `subscribe(.full / .summary)` | pushes start on `HelperEventsXPC` |
  | `refreshNow`, `pause`, `resume` | as the Live buttons do today |
  | `pauseUntilAppOpens` | sent from `applicationWillTerminate` (owner decision 3) |
  | `status` | `BackgroundStatus` |
  | `recentAlerts(since:)` | `[Alert]` from the ring: the "while HeatLens was closed" list |
  | `historyWindow(since:)`, `savedActions(since:)`, `historySize` | as `HistoryStore` answers today |
  | `recordActions([ActionRecord])`, `setRetention(days:)`, `deleteHistory` | §3 |
  | `shutdown` | stop sampling, close history, exit; the app then unregisters |

- **Pushes** (`HelperEvent`, helper → app): `tick(LiveTickPayload)` only under `.full`, and
  `summary(status, newAlerts, explanations)`. `LiveTickPayload` is `LiveTick` made `Codable`. That
  means adding `Codable` to `LiveTick`, `LiveHistory.Window`, `ProjectBreakdown`/`ProjectUsage`,
  `Alert`, and `HistoryPoint`/`HistoryProjectPoint`/`TimelineEvent`/`HistoryWindow`. Most of
  `Model/` already is.
- **Read messages** (`HelperReadRequest`, CLI → helper): `liveStatus`, `recentAlerts(limit:)` and
  `explanations`, and nothing else. With the MCP switch off, or with the helper unconfigured or
  paused, every read returns `.notRunning("Background monitoring isn't running in HeatLens")`
  (owner decision 7). A read connection never changes the mode.
- **The app reads live data** by subscribing: `.full` while the Live view is visible and
  `.summary` otherwise. `LiveModel` keeps its shape: it consumes a stream of `LiveEvent`s, whether
  they come from the in-process core (v2.0) or from `HelperClient` (v2.1).

### 3. What runs where

| Runs in the helper (v2.1) | Stays in the app, always |
|---|---|
| `LiveMonitor` sampling, `SamplingPolicy` | All UI: panel, Live, Settings, sheets |
| `ConcurrencyRules`, `TimelineDetector`, `AlertEvaluator`, watchlists | Posting notifications (`LiveAlertService`, `ThermalAlertService`) |
| `HistoryRecorder` → `HistoryStore` (sole owner of the file while running) | One-off scans (`ScanPipeline`, `ps`, ports, power assertions) |
| The recent-alerts ring | **Every action:** stop requests, force quit, container stop, batch stop, and the `StopLedger` |
| The two read-only XPC surfaces | Incident export (reads from the helper; writes only where the Save panel says) |

- **The helper never signals and never writes to Docker.** It doesn't link `ProcessTerminator`,
  `BatchStop`, `ContainerStopper` or `StopLedger`. Neither request type has an action case. A grep
  test pins this: no `kill(`, `requestStop`, `forceQuit`, `ContainerStopper`, `"POST "` or
  `StopLedger` in `Sources/heatlens-helper/` or `Sources/HeatLensCore/Background/`. ADR-0006
  "Revisit when" therefore doesn't trigger. The ledger, the 5 s / 60 s rules and the confirmations
  stay in the app, unchanged. If a later ADR ever moved a signal into the helper, it would have to
  move the ledger and those rules with it, and the helper would need its own ledger entry before
  any force quit (ADR-0006).
- **One history writer at a time.** While the helper runs it is the only process with
  `history.sqlite` open. `ActionLog` sends `recordActions` instead of opening the store, and
  Delete history and retention changes go over XPC as well. When the helper isn't running, the
  app opens the store as it does today. ADR-0005's rules (folder `0700`, file `0600`, `lstat`,
  `SQLITE_OPEN_NOFOLLOW`, bound values) hold in whichever process has it open.

### 4. Opt-in and lifecycle

**The switch.** Settings gains a "Background" group with **"Keep watching in the background"**
(`UserDefaults` key `keepWatchingInBackground`, default **false**). The caption reads: *"After you
close the panel, HeatLens keeps sampling every 30 s (60 s on battery, 5–10 s while something is
busy) so alerts and history keep working. Quit HeatLens to stop."* Below it is a status line, for
example "Watching · every 30 s (idle, on power)", or "Paused" with the reason.

| Event | v2.0 (in-app) | v2.1 (helper) |
|---|---|---|
| Switch turned on | Background mode starts at once; panel close no longer stops Live | `SMAppService.agent(plistName:).register()`; if it needs approval, Settings says "Allow HeatLens in System Settings → General → Login Items" with a button that calls `SMAppService.openSystemSettingsLoginItems()`; meanwhile it runs in-app |
| Panel closes | Background cadence | `setViewer(attached: false)` |
| Pause (Live button) | Paused until Resume or the next launch | `pause` |
| **Quit HeatLens** | The process ends; nothing samples | `pauseUntilAppOpens`, then the app quits. The helper stops sampling, keeps no state, and exits once idle for 60 s |
| App crash or `kill` | Nothing samples | The helper sees the connection invalidated *without* `pauseUntilAppOpens` and keeps sampling. With no app connected for **1 hour** it pauses until the app opens, so a deleted or broken app can't leave a sampler running |
| App opens | Background mode resumes if the switch is on | `hello` + `configure`; alerts raised since the app was last connected are listed once ("While HeatLens was closed: 2 alerts") |
| Launch at login | The existing `SMAppService.mainApp` switch; with both on, watching starts at login | Unchanged: the agent has **no `RunAtLoad` and no `KeepAlive`**. The app launching at login connects and so starts it. One login switch, not two |
| Switch turned off | Back to v1 behaviour: Live only while watching | `shutdown`, then `unregister()` (owner decision 3) |

**The helper bundle layout (v2.1).** Per Apple's
[Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle):

- `Contents/Helpers/heatlens-helper` is the executable, next to the CLI. The name can't collide with
  `heatlens` or `HeatLens` on a case-insensitive volume (project.yml's comment on the CLI).
- `Contents/Library/LaunchAgents/dev.heatlens.HeatLens.helper.plist` holds `Label`
  `dev.heatlens.HeatLens.helper`, `BundleProgram` `Contents/Helpers/heatlens-helper`,
  `MachServices` with both names, `AssociatedBundleIdentifiers` `[dev.heatlens.HeatLens]` and
  `ProcessType` `Adaptive`. There's no `RunAtLoad`, `KeepAlive` or `Program`.
  [`SMAppService.agent(plistName:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:))
  registers it from inside the bundle (macOS 13+; see
  [Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)).
  `launchd.plist(5)` documents `BundleProgram`, `MachServices` and `ProcessType`.

**Uninstall.** Every artefact is listed so removal is clear. `docs/RELEASING.md`/README text is
Jarvis's to add.

| Artefact | v2.0 | v2.1 | How it goes |
|---|---|---|---|
| Preferences `dev.heatlens.HeatLens` | yes | yes | `defaults delete dev.heatlens.HeatLens` |
| `~/Library/Application Support/HeatLens/history.sqlite` (+ `-wal`, `-shm`) | only if Keep history was on | same | Settings → Delete history, or remove the folder |
| Background Task Management record of the agent | no | yes | Turning the switch off calls `unregister()`. If the app is trashed while registered, the plist and executable go with the bundle, so launchd has nothing to start. The record may stay listed in System Settings → General → Login Items until macOS prunes it (Apple: [Manage login items and background tasks](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)). Brief 4k verifies and records what a trashed app leaves |
| Unified log entries (`subsystem dev.heatlens`) | yes (4d) | yes | Expire under macOS's own log retention; no file of ours |
| Anything outside the user's home, any root-owned file, any daemon | no | no | — |

### 5. Signing, notarization, sandbox

- **Sandbox and entitlements:** none. The app is unsandboxed with the hardened runtime and no
  entitlements file (FEASIBILITY §7: the sandbox loses `proc_listallpids`, others' `rusage` and
  the `ps` fallback). The helper inherits that choice and needs no entitlement: a per-user
  LaunchAgent with Mach services needs none outside the sandbox. Time Sensitive notifications
  *would* need `com.apple.developer.usernotifications.time-sensitive`. Owner decision 2 rules
  them out, so no entitlement changes.
- **v2.0:** no change at all to signing or notarization.
- **v2.1:** one more nested executable. `scripts/release.sh` already signs every
  `Contents/Helpers/*` with `--options runtime` and the identifier `dev.heatlens.<basename>`, so
  the helper is signed as `dev.heatlens.heatlens-helper` before the app with no script change. The
  agent plist is a resource sealed by the app's signature, so editing it breaks the seal. The
  existing zipped-app notary submission covers nested code
  ([Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)).
  Jarvis verifies `codesign --verify --strict` on the helper and `spctl` on the DMG, as today.
- **Debug builds** are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`). `SMAppService` can't register
  them: Settings already says launch at login is "Unavailable for this build". They also carry no
  team ID, so they can't satisfy the requirement. Debug therefore always runs the v2.0 in-app
  mode. The XPC code is tested in-process through
  [`NSXPCListener.anonymous()`](https://developer.apple.com/documentation/foundation/nsxpclistener/anonymous()).
  The real LaunchAgent path is verified only on a build **Jarvis signs** (Apple Development or
  Developer ID).
- **Version skew.** The helper executable lives inside the app bundle, so updating the app replaces
  it. A helper still running from the old bundle answers the new app's `hello` with
  `.restartRequired` and exits, and launchd starts the new binary on the next message. A protocol
  major mismatch is refused on both sides with "HeatLens and its background helper are different
  versions; quit and reopen HeatLens".

### 6. Overhead budget

Measured the way [PERFORMANCE.md](../PERFORMANCE.md) §2.8 measures Live: release build, wrapped in
`/usr/bin/time -l`, about 800 processes, hardware sensors on, plus `ps -o %cpu=,rss=,time= -p
<pid>` taken 60 s apart and `top -l 2 -pid <pid> -stats pid,cpu,mem,idlew,power` for the app or
helper. The baseline is a tick costing about 56 ms of CPU (§2.8.6: 0.73 s for ~13 ticks).

| Situation | Interval (owner decision 8) | Expected CPU | Budget |
|---|---|---|---|
| Idle, on power | 30 s | ~0.19% of one core | **≤ 0.3%** |
| Idle, on battery | 60 s | ~0.09% | **≤ 0.2%** |
| Low Power Mode | 120 s, never fast | ~0.05% | **≤ 0.1%** |
| Incident, on power / battery | 5 s / 10 s | ~1.1% / ~0.6% | **≤ 2%** (ADR-0003's Live budget) |
| Panel open on Live | user's 2/5/10 s | as today | ADR-0003 |

- **Memory:** v2.0 adds nothing beyond today's Live ring (bounded at 150 ticks, so 75 minutes at
  30 s). Growth must stay **< 30 MB over 1 hour** in background. The v2.1 helper's footprint must
  be **≤ 25 MB** (the probe peaked at 19.4 MB over 15 minutes, §2.8).
- **Wake-ups:** one timer per interval and none between ticks. `ProcessType Adaptive` lets launchd
  treat the helper as background work except while it answers the app.
- **XPC cost:** a `.full` push of a 1,000-process tick must encode and decode in **≤ 80 ms of CPU**
  (test `tickCost`). The original 5 ms target wasn't reachable with `Codable`. Measured in
  4j (release): 24 ms encode + 31 ms decode, 358 KB on the wire, and the cost is almost all
  Foundation's `Codable`, not the plist format. JSON is no faster, and dropping the process
  list still leaves ~21 ms. Only `.full` pushes pay it, and only while the Live view is visible.
  That's ~1.1% of one core at 5 s, but ~2.7% at the 2 s picker, which is over ADR-0003's 2%.
  4k measures this end to end and, if needed, slims `.full` to the top lists and groups. A
  hand-written binary format was rejected: it would put a custom parser at the security
  boundary. `.summary` pushes are a few KB. (Ruling 2026-10-28, on 4j's question.)
- **Proving command** (4a adds the flag): `/usr/bin/time -l .build/release/heatlens-probe
  --background 900`, which prints each tick's interval, its reason and its cost. Results go in
  PERFORMANCE.md §2.9.

## Security review

The method follows [SECURITY-REVIEW-3d](SECURITY-REVIEW-3d.md): reading only, no probing. Nothing
was registered, loaded or connected for this review.

**What changes in the trust model**

| Boundary | Before | v2.0 | v2.1 |
|---|---|---|---|
| Processes | One app | Same | App + a per-user agent, started on demand, never root |
| Listeners | None (ADR-0003) | None | Two Mach services, each with a code-signing requirement |
| Who can read live data | The app's UI; MCP sees one-off scans only | Same | Plus the signed CLI, only with the MCP switch on, and only while sampling |
| Who can act on processes or containers | The user, in scan results | Same | Same: the helper has no action path |
| Sampling without the panel | Never | With the switch on, until Quit | Same, plus up to 1 h after an app crash |

**Threats**

| # | Threat | Mitigation | Proof |
|---|---|---|---|
| 1 | Another local process connects to the helper and reads what HeatLens sees | Each listener's code-signing requirement pins the anchor, team `9PXJ82UU32` and identifier; the system checks the audit token per connection | Test: the ad-hoc test runner does **not** satisfy the release requirement (`SecRequirementCreateWithString`, then `SecCodeCheckValidity` on `SecCodeCopySelf`); click-through on the signed build: an unsigned copy of the CLI is refused |
| 2 | The app talks to an impostor helper | The app's `setCodeSigningRequirement` pins `dev.heatlens.heatlens-helper` and the team. The Mach service name comes from the plist inside the sealed bundle | Same requirement test, mirrored |
| 3 | The read service is used to change state | `HelperReadXPC` decodes only `HelperReadRequest`, which has three read cases. It can't decode a control request, and it never changes the mode | Test: a control envelope sent to the read handler → decoding error, mode unchanged |
| 4 | A hostile or corrupt payload | Size cap (8 MB) before decoding; binary plist `Codable`; protocol-version check; unknown cases → error reply; NSSecureCoding only for `NSData` | Tests: oversize, truncated, wrong version, unknown case |
| 5 | The helper signals or writes to Docker | Not linked; no action case in any request; grep test (§3) | Grep test in `HelperProtocolTests` |
| 6 | The helper is a way to start sampling without consent | Nothing starts it at login (`RunAtLoad` absent). A read connection on an unconfigured helper gets `.notRunning`. Only `configure` from the app, with the switch on, starts sampling | Test: a fresh `HelperServer` answers reads with `.notRunning` and has no live session |
| 7 | Sampling outlives the app forever (crash, app deleted) | 1-hour orphan pause; on-demand job; the plist goes with the bundle | Test with an injected clock: no `hello` for 3,600 s → paused |
| 8 | The app is replaced or downgraded | `hello` build check → `.restartRequired`; protocol-major check on both sides. A downgrade to v2.0 has no plist, so the old registration can't start anything. v2.1 release notes tell users to turn the switch off before downgrading | Tests: build mismatch, major mismatch; 4k records what a downgrade leaves |
| 9 | Code injected into the app or helper | Hardened runtime; no `disable-library-validation` and no `allow-dyld-environment-variables` entitlement, so `DYLD_INSERT_LIBRARIES` is ignored. The agent plist is sealed | `codesign -d --entitlements - ` shows none (Jarvis, at release) |
| 10 | New files, or files with loose permissions | The helper creates nothing but the history store, under ADR-0005's rules; no socket files; no config file (settings arrive by `configure`) | HistoryStore permission tests, unchanged |
| 11 | Data leaves the Mac | No network code in the helper; the MCP read tools answer over stdio to the agent that launched the CLI, redacted like the scan tool | Grep test: no `URLSession` or `Network` import in the helper or `Background/` |
| 12 | Alerts break through Focus | `.active` interruption level, set explicitly (owner decision 2) | Code read in 4c |
| 13 | TCC prompts from a background process | `ProjectRootLocator` already skips protected folders (Desktop, Documents, Downloads); libproc, SMC and the Docker socket need no TCC | 4k click-through: no prompt appears with the helper running |

**Residual risk.** A process running as the same user with a validly signed HeatLens binary
(for example a copy of the CLI run by another tool) can read live status while the MCP switch is
on. That is the documented purpose of the switch, and the data is what the scan tool already
returns. **Verdict:** no finding blocks the design.

## Options considered

| Option | Signing and notarization | Sandbox and entitlements | Uninstall clarity | Against |
|---|---|---|---|---|
| **C. Keep the app alive with no panel (chosen for v2.0)** | None | None | Nothing new | The app's full footprint stays resident; it can't survive a crash, and it can't offer a Mach service to the CLI |
| **A. `SMAppService` LaunchAgent with XPC (chosen for v2.1)** | One nested executable, already covered by `release.sh`'s Helpers loop; covered by the app's notarization | None | Good: a switch registers and unregisters; the plist and executable live inside the bundle | Two processes, an IPC protocol, history ownership, and it can only be verified on a signed build |
| B. Login-item app (`SMAppService.loginItem`, a second `.app` in `Contents/Library/LoginItems`) | A nested app bundle, signed inside-out, with its own Info.plist | None | Same BTM entry | A second app identity (its own notification permission and Dock/Login Items name); runs at login rather than on demand |
| An XPC service bundle (`Contents/XPCServices`) | Nested bundle | None | Good | Lives and dies with the app, so it gains crash isolation only; the CLI can't reach it |
| A privileged daemon (`SMAppService.daemon`) | Nested, plus an admin approval | Root | Poor | PRD-v2 §8: no root for ordinary monitoring |
| A localhost HTTP or Unix-socket server | — | — | — | ADR-0003 and PRD-v2 §5: the origin, CSRF and peer problems XPC avoids |
| The helper posts its own notifications | — | Needs an app bundle identity: a bare tool has none | — | Owner decision 3: one notification identity, posted by the app |

## Revisit when

- Anything proposes that the helper act on a process or container. ADR-0006 "Revisit when"
  applies in full, and this ADR's §3 rule must be replaced, not bent.
- macOS raises the deployment target to one with the Swift `XPCSession` peer-requirement API.
  It could replace the `NSXPCConnection` wrapper; the message types stay.
- The 1-hour orphan rule surprises users: shorten it, never remove it.
- Owner decision 3 changes (the helper keeps sampling after Quit). That needs a menu-bar
  indicator the user can't miss and a second look at notifications.

## Build briefs

Each brief ends green on `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift
build && swift test` and `scripts/run-app.sh --build-only`. The order across Phase 4 is in
[PHASE-4-PLAN.md](PHASE-4-PLAN.md#order). The four briefs here are **4b** and **4c** (v2.0) and
**4j** and **4k** (v2.1). 4b needs 4a (adaptive sampling).

### 4b · Core: `BackgroundMonitor` (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Background/BackgroundMonitor.swift` (new): `public actor
    BackgroundMonitor`. It owns one `LiveMonitor` and gives it `LiveConfiguration(sampling:
    SamplingPolicy, autoPauseAfter: nil)` from 4a. API: `configure(_: LiveConfiguration,
    keepWatching: Bool)`, `viewerAttached(interval:)`, `viewerDetached()`, `pause()`, `resume()`,
    `refreshNow()`, `subscribe(_: Subscription) -> AsyncStream<BackgroundEvent>` (`.full`,
    `.summary`), `status`, `recentAlerts(since:)`, `explanations`. `BackgroundEvent`: `tick`,
    `status`, `alerts([Alert])`, `stopped(reason)`. `BackgroundStatus`: mode, interval, reason,
    since, last tick time and cost.
  - Rules: with `keepWatching` false it behaves exactly like today's `LiveModel` +
    `LiveMonitor` pair (foreground only, 15-min auto-pause, stops when the viewer detaches). With
    it true, viewer detach → background cadence, and 15 minutes of foreground → background
    cadence. Recent-alerts ring of 50. One `AlertEvaluator` for the actor's life (cooldowns hold
    across modes, as `LiveMonitor` does across sessions).
  - `Tests/HeatLensCoreTests/BackgroundMonitorTests.swift` (new): fake samplers and the
    instant-sleep init from `LiveMonitorTests`. Covers: no work before `configure` or while
    paused; keepWatching off → detach stops; on → detach changes cadence (the recorded sleep
    durations follow the policy); a forgotten foreground falls back after 15 min (injected
    clock); the ring is bounded; `.summary` subscribers get no ticks; cancelling every
    subscription doesn't stop a background session but does stop a foreground-only one.
- **Pattern to copy:** `LiveMonitor`'s session ID and `stop(session:)` guard, and the
  `AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))` per subscriber; `LiveMonitorTests`
  fakes.
- **Done when:** the tests pass three runs in a row under `scripts/with-timeout.sh 600`, and
  `grep -rnE "kill\(|requestStop|forceQuit|ContainerStopper|StopLedger" Sources/HeatLensCore/Background/`
  prints nothing.
- **May touch:** `Sources/HeatLensCore/Background/BackgroundMonitor.swift` (new),
  `Tests/HeatLensCoreTests/BackgroundMonitorTests.swift` (new),
  `Sources/HeatLensCore/Live/LiveMonitor.swift` (only if 4a left a hook missing; name it).
- **Must not touch:** `App/`, `Model/`, `Package.swift`, `project.yml`, the CLI targets, docs.

### 4c · App: "Keep watching in the background" (claude, opus, medium)

- **Do:**
  - `App/SettingsModel.swift`: `keepWatchingInBackground` (key `keepWatchingInBackground`, default
    false, the `dockerEnabled` `didSet` pattern). `App/SettingsView.swift`: a "Background" group
    after Alerts, with the toggle, the §4 caption and the status line.
  - `App/LiveModel.swift`: drive `BackgroundMonitor` instead of `LiveMonitor`; `start()` becomes
    `viewerAttached`; add `viewerClosed()`. Settings changes call `configure` (the same
    observation pattern as `LiveAlertService.followSettings`).
  - `App/HeatLensApp.swift`: `statusPanel.onClose = { live.viewerClosed() }`. At launch with the
    switch on, `configure` starts background mode without opening the panel. `App/PopoverView.swift`:
    switching to Scan detaches the viewer instead of stopping.
  - `App/LiveAlertService.swift`: set `content.interruptionLevel = .active` explicitly (owner
    decision 2); post whether or not the panel is open (it already follows `latest`; make it
    follow `BackgroundEvent.alerts` so a closed panel still posts).
  - `App/LiveView.swift`: a header line, "Watching in the background · every 30 s (idle, on
    power)"; Pause pauses watching until Resume or the next launch.
  - `App/StatusPanel.swift`: the status item's tooltip names the mode ("HeatLens: watching in the
    background").
  - `App/AlertSettingsSection.swift`: the caption "checked while Live runs" becomes "checked while
    Live runs or HeatLens is watching in the background".
- **Pattern to copy:** the `dockerEnabled` toggle and caption; `LiveAlertService`'s observation loop;
  `ThermalAlertService` for notification delegate behaviour (click opens the panel).
- **Done when:** the app builds with no new warnings, and the click-through below works.
  Verification steps for the handoff:
  1. `scripts/run-app.sh`.
  2. Settings → Alerts on, CPU at 60 %; Background on.
  3. Close the panel. In Terminal, start enough `yes > /dev/null &` jobs to load at least 70 %
     of all cores (8 on the 11-core M3 Pro). These are the worker's own fixtures, stopped by PID
     afterwards.
  4. Within about 2.5 minutes a notification arrives with the panel closed, and Live's header
     reads "every 5 s (incident)". Stop the `yes` processes by PID.
  5. Within 2 minutes after that, the header is back to "every 30 s (idle)".
  6. `ps -o time= -p <app pid>` 60 s apart grows ≤ 0.3 s once idle.
  7. Quit: no HeatLens process remains. Switch off: closing the panel stops Live, as in v2.0 today.
- **May touch:** `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/LiveModel.swift`,
  `App/HeatLensApp.swift`, `App/PopoverView.swift`, `App/LiveAlertService.swift`, `App/LiveView.swift`,
  `App/StatusPanel.swift`, `App/AlertSettingsSection.swift`.
- **Must not touch:** `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs (Jarvis updates
  README, LIMITATIONS and CLICKTHROUGH where they say Live stops when the panel closes).

### 4j · Core (v2.1): helper protocol, codec and XPC server/client (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Background/HelperProtocol.swift` (new): `HelperEnvelope`,
    `HelperControlRequest`/`Reply`, `HelperReadRequest`/`Reply`, `HelperEvent`,
    `BackgroundSettings`, `protocolVersion = 1`, the two Mach service names, and the three
    requirement strings as constants.
  - `Sources/HeatLensCore/Background/HelperCodec.swift` (new): binary-plist encode and decode, the
    8 MB cap, version check.
  - `Sources/HeatLensCore/Background/HelperXPC.swift` (new): the `@objc` protocols
    (`HelperControlXPC`, `HelperReadXPC`, `HelperEventsXPC`); `HelperServer` (maps requests to a
    `BackgroundMonitor` and a `HistoryStore`, owns the orphan timer, answers reads with
    `.notRunning` unless configured and the MCP switch is on); `HelperClient` (app side:
    connect with requirement, reconnect with backoff 1/2/5/10 s on invalidation, replay `hello` +
    `configure` + viewer + subscription); `HelperReadClient` (CLI side).
  - `Codable` on the tick types listed in §2. These are shared files, so keep the edit to the
    conformance and name each file in the handoff: `Live/LiveMonitor.swift`,
    `Projects/ProjectBreakdown.swift`, `Rules/AlertPolicy.swift`, `History/HistoryModel.swift`.
  - Tests, new: `HelperProtocolTests.swift` (round trip of every case; oversize, truncated, wrong
    version, unknown case; a 1,000-process tick encodes and decodes under 5 ms in release and
    under 50 ms in debug; the §3 grep test; no `URLSession`/`Network` in `Background/`; the
    ad-hoc runner fails the release requirement) and `HelperXPCTests.swift` (end to end over
    `NSXPCListener.anonymous()` with no requirement: hello, configure, subscribe `.full` gets
    ticks, `.summary` doesn't, a read on an unconfigured server → `.notRunning`, a control
    envelope on the read handler is refused, build mismatch → `.restartRequired`, the orphan
    pause with an injected clock, `recordActions` lands in the store).
- **Pattern to copy:** `MCPServer`'s strict argument handling (unknown → error, never a crash);
  `HistoryStoreTests` temp-directory stores; `LiveMonitorTests` fakes.
- **Done when:** all of the above pass three runs in a row under `scripts/with-timeout.sh 600`, and
  every existing test passes unchanged (`ModelCodableTests` included).
- **May touch:** the three new `Background/` files, the two new test files, and the four shared
  files named above (conformance only).
- **Must not touch:** `App/`, `Package.swift`, `project.yml`, the CLI targets, `Safety/`,
  `Docker/`, docs.

### 4k · Helper target, registration and the app client (claude, opus, high; verification needs a build Jarvis signs)

- **Do:**
  - `Sources/heatlens-helper/main.swift` (new): two `NSXPCListener(machServiceName:)` with
    `setConnectionCodeSigningRequirement`, a `HelperServer`, and `dispatchMain()`. It exits after
    60 s with no session and no connection.
  - `Package.swift`: `.executableTarget(name: "heatlens-helper", dependencies: ["HeatLensCore"])`
    (shared file; name it).
  - `project.yml`: a `heatlens-helper` tool target embedded at `Contents/Helpers` like
    `heatlens-cli`, and a copy phase putting `App/LaunchAgents/dev.heatlens.HeatLens.helper.plist`
    (new) at `Contents/Library/LaunchAgents` (shared file; name it).
  - `App/HelperConnection.swift` (new): `SMAppService.agent(plistName:)`
    register/unregister/status; `HelperClient` use; the fallback to in-app mode with the reason.
  - `App/LiveModel.swift`, `App/HistoryService.swift` (`ActionLog` sends `recordActions` and
    Delete history while the helper owns the store), `App/HeatLensApp.swift`
    (`applicationWillTerminate` → `pauseUntilAppOpens`; "While HeatLens was closed" on open),
    `App/SettingsView.swift` (approval state and button).
- **Pattern to copy:** the `heatlens-cli` target and embed in `project.yml`; `SettingsModel`'s
  `SMAppService.mainApp` status mapping for launch at login.
- **Done when:** `swift build`, `swift test` and `scripts/run-app.sh --build-only` pass; a Debug
  build shows "Background helper unavailable for this build; watching inside HeatLens" and
  behaves as 4c. **Verification needs a signed build. The worker stops there and Jarvis
  runs the rest:**
  1. Signed build; the switch on; approve in Login Items.
  2. `launchctl print gui/$(id -u)/dev.heatlens.HeatLens.helper` shows the job (Jarvis only).
  3. Close the panel, quit the app's UI with `kill -ABRT <app pid>`: the helper keeps sampling and
     an alert fired meanwhile is listed when HeatLens reopens.
  4. Quit HeatLens properly: the helper stops sampling and exits within about 60 s.
  5. An unsigned copy of the CLI is refused; switch off → `unregister`, and the job is gone.
  6. Trash the app while registered and record what Login Items still shows.
  7. Overhead per §6, recorded in PERFORMANCE.md §2.9.
- **May touch:** the files named above.
- **Must not touch:** `App/*.entitlements` (there are none; don't add one), `Safety/`, `Docker/`,
  `scripts/release.sh` (its Helpers loop already signs the helper; if it doesn't, say so in the
  handoff and leave the change to Jarvis), docs.
