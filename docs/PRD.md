# HeatLens — Product Requirements Document

**Version:** 1.0 | **Status:** Build-ready specification | **Platform:** macOS (Apple Silicon first)

## 1. Product vision

HeatLens is a tiny, on-demand macOS menu-bar diagnostic app that explains **why a Mac is hot, noisy, slow, or under resource pressure**, without requiring the user to remember Terminal commands. One click captures a short diagnostic snapshot, connects expensive processes to the projects and tools that launched them, distinguishes active work from possible leftovers, and recommends safe next steps. It must not become another persistent resource hog.

**Core promise:** “Click once. See what's using your Mac, why, and what you can safely do.”

### Motivation / real incident

On a MacBook Pro M3 Pro with 18 GB unified memory, the user runs Claude Code, OpenCode, Superset, Next.js, Docker, and video-editing workflows. Activity Monitor showed high CPU from `kernel_task`, `WindowServer`, Node processes and agent helpers. A subsequent `ps` inspection revealed:

- A `thought-expirements/scripts/worker.js` process with PPID 1 running for >2 days, despite the project not being used.
- A portfolio `next dev -p 3100` process running >1 day, although no local server was needed.
- Legitimate high-CPU workers editing video and running Jarvis tasks; these should **not** be treated as junk or killed.

The problem is not just temperature: it is **lack of process provenance and confidence about what is safe to stop**.

## 2. Goals and non-goals

### Goals

1. One-click, human-readable diagnosis of current CPU, memory, swap, GPU/UI proxy indicators, thermal pressure, and relevant background processes.
2. Group related processes by application, project directory, parent/child tree, and task type.
3. Identify *candidates* for stale dev servers, orphaned workers, long-lived idle services, and runaway processes; never equate age or PPID 1 with being stale.
4. Explain evidence, uncertainty, and impact in plain English.
5. Offer explicit, reversible-where-possible remediation; **never auto-kill**.
6. Keep idle footprint extremely low: no constant polling, no periodic subprocesses, no required privileged helper.
7. Operate offline by default; no telemetry or code/file-content upload.

### Non-goals (v1)

- Measuring physical CPU temperature on every Mac; public APIs do not guarantee accurate per-chip temperature access.
- Guaranteed identification of a process's *intent* or whether an AI agent has finished.
- Kernel extensions, SIP bypass, SMC hacks, undocumented sensor scraping, or elevated root privileges.
- Automatically closing projects, editing user files, or modifying agent sessions.
- Always-on alerts or continuous historical monitoring in the MVP.
- Full Activity Monitor replacement.

## 3. UX and interaction

### Entry point

A native `MenuBarExtra` icon (thermometer/gauge) in the macOS menu bar. Clicking opens a compact SwiftUI popover. Prefer the menu bar over Dynamic Island / camera-notch overlays for v1: Mac notch UI is not a public system surface, and overlay approaches add complexity and accessibility concerns. A notch-inspired panel may be explored later as an optional feature.

The app has no Dock icon by default (`LSUIElement = YES`). No main window is required except optional detail/settings views.

### Primary flow

1. User clicks icon.
2. Popover opens instantly with “Run diagnosis” and last snapshot timestamp (if one exists).
3. User clicks **Scan now**. Collect a 5–10 second bounded sample with visible progress and Cancel.
4. Show a clear status: **High load observed**, **Thermal pressure reported**, **Memory pressure**, or **No significant issue observed**. Do not label actual thermal cause as certain without evidence.
5. Show top contributors and groupings, with expandable evidence and safe actions.
6. User can inspect a process, open its project folder, copy diagnostic summary, or request a graceful stop.

### Result card example

**Possible leftover development worker — Review**

`node …/thought-expirements/scripts/worker.js` · PID 12874 · elapsed 2d 5h · 0% CPU in sample · PPID 1

**Why flagged:** long-lived project worker, parent adopted by launchd, project not currently recognized as foreground; **this does not prove it is unused**.

**Impact now:** negligible measured CPU; stopping it is unlikely to fix current heat.

**Actions:** Inspect details · Open project · Copy command · Request stop

### UI sections

- **Overview:** thermal pressure if available, total CPU load, memory pressure, swap used, CPU top contributors, sample time and data-quality notices.
- **What's using resources:** grouped applications/process trees; CPU during sample; memory footprint; elapsed runtime; optional disk/network deltas.
- **Potential leftovers:** long-running dev servers, detached workers, known build/test processes. Always show confidence and actual current impact.
- **Actions:** review process and terminate only after confirmation; open in Activity Monitor; copy commands/report.
- **Settings:** sample duration (5/10/15 s), excluded projects/processes, privacy, optional local history, launch-at-login preference (off by default).

## 4. Technical architecture

**Recommended:** native **Swift + SwiftUI**, targeting a currently supported macOS SDK, with a small diagnostics engine written in Swift and a minimal C bridge only if required for public libproc/sysctl APIs. Use no Electron, Node runtime, embedded browser, or mandatory backend.

```text
SwiftUI MenuBarExtra / popover
            |
      ScanCoordinator (async, cancellable)
            |
  +---------+----------+----------------+
  |                    |                |
ProcessSampler     SystemSampler   ProvenanceResolver
  |                    |                |
libproc/sysctl,     host_statistics,   process parent tree,
proc_pidinfo,       vm statistics,     executable path,
getrusage as       ProcessInfo,       argv/cwd where permitted,
applicable         memory_pressure    project fingerprints
  +--------------------+----------------+
                       |
                 RulesEngine
                       |
             Evidence-backed findings
                       |
              SwiftUI result cards
                       |
             User-approved actions
```

### 4.1 Collection strategy

- Collect baseline and final process CPU counters, separated by a short monotonic sampling interval. Calculate CPU utilization from **delta CPU time / elapsed wall time**, normalized and labeled consistently. A process can exceed 100% when using multiple cores. Do not present cumulative CPU time as current utilization.
- Enumerate process IDs using documented/public facilities such as `proc_listpids`, `proc_pidinfo`, `proc_pidpath` where permitted; verify signatures and availability against installed macOS SDK. Fallback to read-only `ps` subprocesses if needed. Avoid running shell pipelines or commands via an interactive shell.
- Gather PID, PPID, executable name/path, launch/start time, CPU delta, resident/physical footprint when available, and optional arguments/cwd when permissions allow. Track identity as `(pid, startTime)` to avoid PID-reuse mistakes.
- Gather total system CPU load, memory pressure and swap through supported host/vm/sysctl interfaces. Use `pmset -g therm` as an **optional best-effort diagnostic**, parsing defensively; it is not a guaranteed thermal API and may provide limited data on Apple Silicon.
- `kernel_task` high CPU and `WindowServer` high CPU are *signals*, not standalone proof of overheating. High `kernel_task` CPU can reflect thermal management but cannot establish root cause.
- Do not claim GPU utilization without a reliable supported source. Display `WindowServer` CPU as UI/rendering activity, not GPU percentage.
- Disk/network activity are optional follow-ups and should use deltas; skip unavailable counters gracefully.
- Do not inspect source files, terminal history, browser content, tokens, environment variables, or agent transcripts.

### 4.2 Provenance and grouping

Group by parent tree first, then known executable/project hints:

- `next dev`, `vite`, `astro`, `webpack`, `turbo`, `vitest`, `jest`, `tsc --watch`, `node`, `bun`, `pnpm`, `npm`, `yarn`.
- `claude`, `opencode`, Superset workers, Docker processes, CapCut-related apps.
- Project association from process cwd and argv path only where accessible; show “Unknown project” rather than guessing.
- Parent PID 1 is an **orphan/detached clue**, not proof of a leak.
- “Project not in foreground” is weak evidence: background services can be intentional.
- Include raw evidence and confidence score for every inferred label.

### 4.3 Findings engine (deterministic first)

No LLM required for MVP. Use explicit heuristics with tests:

| Finding | Evidence | Severity | Important caveat |
|---|---|---|---|
| Sustained high CPU | CPU delta above threshold in repeated samples | High/medium | May be useful work |
| Memory pressure | OS pressure warning + swap growth | High/medium | RAM usage alone is not pressure |
| Potential stale dev server | Known dev-server command, long runtime, low recent activity | Review | Server may intentionally be always-on |
| Potential detached worker | PPID 1 + project worker + long runtime | Review | Can be an intentional daemon |
| UI-heavy workload | WindowServer sustained CPU, many renderers | Info/review | No causal proof |
| Thermal limitation | Supported OS thermal-state evidence | High/medium | State may be unavailable |

**Priority ranking:** current measured impact first, risk/uncertainty second. A two-day idle process must not outrank an active 80%-CPU video-editing process in a “why hot now” view.

Output structured findings:

```swift
struct DiagnosticFinding: Identifiable, Codable {
    let id: UUID
    let title: String
    let severity: Severity
    let confidence: Confidence
    let explanation: String
    let evidence: [Evidence]
    let limitations: [String]
    let affectedProcessIDs: [ProcessIdentity]
    let recommendedActions: [SuggestedAction]
}
```

### 4.4 Safe remediation

- Default is read-only. No silent process termination, no bulk `pkill`, no `killall node`, no `sudo`, no killing system processes.
- For a user-selected process, show exact PID, full command/path if accessible, parent/children, project association, measured impact, and what might be interrupted.
- Require a confirmation dialog before sending `SIGTERM` to the **specific validated PID**; re-check process identity/start time immediately before action. If identity cannot be verified, disable termination and suggest Activity Monitor.
- After a short wait, re-sample and report result. Do **not** automatically escalate to `SIGKILL`; offer separate advanced manual guidance if needed.
- Never offer termination for `kernel_task`, `WindowServer`, launchd, protected Apple services, or unknown privileged processes.
- Warn that stopping a dev server or agent can interrupt tests, edits, builds, or active sessions. Prefer app-native stop controls when available.
- Provide **Open in Activity Monitor** and **Copy PID/command** as alternatives.

### 4.5 Optional intelligence (post-MVP)

An opt-in **Explain with AI** feature can summarize already-collected, redacted metrics and finding evidence. It must not send raw argv containing secrets, paths, usernames, env vars, source code, or filenames by default. Show exactly what will be sent; obtain explicit consent; no auto-executed model suggestions. Deterministic rules remain source of truth.

## 5. Privacy, security, performance

- Fully local by default; no account, API key, network access, or analytics required.
- No Full Disk Access, Accessibility, Screen Recording, or admin permission requested in v1.
- Where macOS privacy/sandbox restrictions block command lines, cwd, or process details, show “Not accessible” with explanation. Validate entitlement/sandbox/distribution constraints early; a sandboxed Mac App Store build may have reduced visibility. Start with a locally signed/notarized direct-distribution app if necessary, but do not assume permissions bypass OS protections.
- Store only user settings; optional recent snapshots stored locally with configurable retention and deletion.
- Idle CPU target approximately 0% with no timers or polling; aim for <50 MB idle memory (measure, do not promise). Scan duration capped, no unbounded task spawning, cancellation supported.
- Avoid subprocess storms: at most one scan at a time; limited concurrency; cache static metadata per scan.
- Never log sensitive full command lines without user opt-in.

## 6. Functional requirements and acceptance criteria

| ID | Requirement | Acceptance |
|---|---|---|
| FR-01 | Menu bar only | App opens popover without Dock presence; quits cleanly |
| FR-02 | On-demand scan | No scanning when idle; manual 5–10 s scan can be cancelled |
| FR-03 | CPU attribution | CPU percentages derived from interval deltas; multi-core values correctly explained |
| FR-04 | Process details | PID, parent, uptime, executable, memory, CPU shown when accessible |
| FR-05 | Project attribution | Recognizes Next.js, Vitest, Claude/OpenCode, generic Node, Superset heuristically |
| FR-06 | Stale candidates | Long-lived idle dev server/worker flagged as *review*, not confirmed stale |
| FR-07 | Evidence | Every finding includes reason, confidence, and limitations |
| FR-08 | Thermal state | Reports OS thermal state if supported; otherwise “Unavailable” |
| FR-09 | Safe stop | Explicit consent, PID identity revalidation, SIGTERM only, protected-process denylist |
| FR-10 | Privacy | No uploads, no reading project files, no background telemetry |
| FR-11 | Export | Copy concise plain-text or JSON report, redact personal paths by default |
| FR-12 | Resource footprint | No continuous polling; profile idle and active CPU/memory |
| FR-13 | Failure handling | Permission denial, process exit, PID reuse, scan cancellation handled without crash |

## 7. Suggested screens

**Popover / idle:** HeatLens · Last scan: never · [Scan now] · “Nothing is monitored until you scan.”

**Popover / scanning:** “Measuring process activity (7 of 10 seconds)” · [Cancel]

**Popover / results:**

> **High CPU load observed** · 10-second sample
>
> Top contributor: OpenCode worker — 44% CPU (active Jarvis task)
>
> Possible leftover: thought-expirements worker — 2d 5h old, 0% CPU (review only)
>
> Thermal state: unavailable / reported OS state
>
> [See processes] [Review leftovers] [Copy report]

**Process detail:** source, parent tree, CPU graph for sampled interval, exact evidence, caveats, safe actions.

## 8. Implementation plan for Claude Code

### Phase 0 — Feasibility spike (do first)

1. Confirm target macOS version and installed SDK.
2. Build a minimal menu-bar SwiftUI shell.
3. Prototype process enumeration, CPU delta sampling, process ancestry, cwd/argv visibility, memory pressure, and thermal-state availability on the actual M3 Pro.
4. Document which data is available without permissions, with sandboxing, and in direct distribution. Choose supported APIs based on verified SDK docs, not assumptions.
5. Test scan while Claude Code, OpenCode, Next.js, CapCut, and Docker are running.

**Gate:** Do not proceed to a polished UI until reliable process attribution and permission limitations are understood.

### Phase 1 — Read-only MVP

- Implement `ScanCoordinator`, `ProcessSampler`, `SystemSampler`, `ProvenanceResolver`, `RulesEngine` as independent testable modules.
- Build menu bar popover, overview, grouped processes, and findings.
- Add cancellation, redacted export, and error/permission states.
- Add unit tests using synthetic snapshots and fixture processes.

### Phase 2 — Safety and polish

- Add detail screen and explicit SIGTERM action with PID/start-time revalidation.
- Add exclusion/allowlist settings and optional local snapshot history.
- Test performance and memory usage; sign and notarize for personal installation.

### Phase 3 — Future options

- Optional opt-in periodic checks or notifications (off by default).
- Optional notch-inspired overlay, only if native menu bar UX proves insufficient.
- Optional on-device explanation or privacy-gated AI summary.
- Agent-aware integrations that query supported agent APIs/session metadata instead of inferring from process names alone.

## 9. Testing scenarios

1. **Active editing:** CapCut/Claude Code using high CPU; labeled active work, not junk.
2. **Orphan worker:** project worker with PPID 1 for 48h, CPU near zero; “review,” not “causing heat.”
3. **Old Next.js server:** `next dev` running 38h, currently idle; surfaced as possible leftover.
4. **Hot build:** Vitest or Next build spikes CPU for 10s; correctly ranked as current contributor.
5. **PID reuse:** process exits and PID is reused during scan/action; never terminate wrong process.
6. **Restricted process:** command line/cwd inaccessible; UI degrades gracefully.
7. **No thermal info:** thermal status “unavailable,” no fabricated temperature.
8. **Idle app:** after scan, no CPU polling; compare footprint to Activity Monitor.
9. **App quit:** all timers/tasks stop, no helper left behind.
10. **Cancellation:** user closes/cancels mid-scan; no orphan child processes.
11. **Protected processes:** kill controls never offered for critical OS processes.
12. **Multiple cores:** >100% CPU for a process is represented correctly.

## 10. Engineering guardrails / instructions to coding agent

- Build this as a **small, native, on-demand diagnostic utility**, not an AI agent platform.
- Use documented, stable Apple APIs wherever possible; verify with SDK headers/docs before implementation.
- Start read-only. Do not add `sudo`, persistent background launch agents, automatic kill, or telemetry.
- Keep diagnosis deterministic and evidence-based. Separate observation from inference.
- Do not invent temperature readings or promise to identify a unique thermal root cause.
- Use Swift concurrency with structured cancellation and one active scan.
- Unit test scoring, provenance, PID validation, and sensitive-data redaction.
- Deliver source, build/run instructions, sample reports, and a limitations document.

## 11. Definition of done

The user can open HeatLens from the menu bar, click **Scan now**, and within ~10 seconds see (a) the biggest measured current resource consumers, (b) why they are classified as legitimate active work or possible leftovers, (c) whether the OS reports thermal or memory pressure, and (d) safe next actions. Closing the popover or leaving the app idle must not trigger continuous diagnostic work. The app must never terminate a process without explicit, informed confirmation.
