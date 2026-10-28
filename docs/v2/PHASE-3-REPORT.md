# HeatLens v2 — Phase 3 report

Date 2026-10-28. Machine: MacBook Pro M3 Pro, macOS 27.0.1. Docker Engine 28.5.1,
Compose v2.40.3-desktop.1. Plan: [PLAN.md](PLAN.md). Previous: [PHASE-2-REPORT.md](PHASE-2-REPORT.md).

**Exit (PRD-v2):** reproduce the FDA multiple-worker Docker test scenario and receive a
useful explanation and non-destructive recommendation. **Met (Run 2).** With two stand-in
agents kept alive as the parents of their test runs, Live showed a "What's going on" card:
**"2 test runs began within 10 s across 2 agent trees (claude, codex) in FDA, plus 2
containers"**, **High confidence**, with the recommendation **"These test runs compete for the
same CPU cores and the Docker VM. Run them one at a time, or have the agents take turns."**
Projects and Timeline attributed both containers and both test runs to FDA. Run 1 had no card;
the cause was the launch harness, not HeatLens (see [Run 1](#run-1-harness-defect)).

## Changelog

- **3a, Phase 2 verification:** the [click-through](../../handoffs/merged/2026-10-28-1128-v2-3a-clickthrough.md) checked Projects, Timeline, Docker and history; [follow-up fixes](../../handoffs/merged/2026-10-28-1133-v2-3a-fixes.md) added Live process-detail navigation and corrected history wording ([ADR-0004](ADR-0004-project-attribution.md), [ADR-0005](ADR-0005-history-store.md)).
- **3b, concurrency explanations:** [rules and card](../../handoffs/merged/2026-10-28-1128-v2-3b-concurrency-explanations.md) connect expensive commands, agent ancestry and container starts to observations, confidence, uncertainty and advice; Timeline marks the inference.
- **3c, alerts:** [alert policies](../../handoffs/merged/2026-10-28-1215-v2-3c-alert-policies.md) add Live-only CPU, memory, swap, thermal and container thresholds with hysteresis, cooldown, notifications and banners.
- **3d, safety design:** the [design handoff](../../handoffs/merged/2026-10-28-1150-v2-3d-safe-actions-design.md) records [ADR-0006](ADR-0006-force-quit.md), [ADR-0007](ADR-0007-docker-container-stop.md) and the [security review](SECURITY-REVIEW-3d.md).
- **3d-1, force-quit engine:** the [core implementation](../../handoffs/merged/2026-10-28-1215-v2-3d1-force-quit-core.md) gates force quit on a recorded stop request, grace period, expiry and renewed identity/eligibility checks ([ADR-0006](ADR-0006-force-quit.md)).
- **3d-2, force-quit app:** the [app implementation](../../handoffs/merged/2026-10-28-1225-v2-3d2-force-quit-app.md) adds the opt-in setting, separate confirmation and individual batch-row offer; Live remains read-only ([ADR-0006](ADR-0006-force-quit.md)).
- **3d-3, container-stop engine:** the [core implementation](../../handoffs/merged/2026-10-28-1225-v2-3d3-container-stop-core.md) restricts the Docker write to one validated container-stop endpoint with identity, eligibility and socket checks ([ADR-0007](ADR-0007-docker-container-stop.md)).
- **3d-4, container-stop app:** the [app implementation](../../handoffs/merged/2026-10-28-1232-v2-3d4-container-stop-app.md) adds the opt-in setting, scan-result container detail and explicit confirmation ([ADR-0007](ADR-0007-docker-container-stop.md)).
- **3e-1, action records:** the [action log](../../handoffs/merged/2026-10-28-1600-v2-3e1-action-log.md) keeps the newest 500 session records, exposes Recent actions and persists records only with history enabled ([ADR-0005 addendum](ADR-0005-history-store.md#addendum-3e-action-records)).
- **3e-2, exclusions and cancellation:** [ignore/cancel logging](../../handoffs/merged/2026-10-28-1254-v2-3e2-ignore-and-cancel.md) records process/project exclusions and cancelled action confirmations.

## Tests

Before each run, `swift build`, `swift test` and the app build ran under the suite lock. The
last one, before Run 2: **363 tests in 58 suites passed**, and the Debug app built. Both runs
used that build. No source files were changed for this verification.

## Run 1 (harness defect)

The first exit run, kept as recorded. Its verdict is superseded by Run 2.

### Run 1 preparation and starting settings

The user's earlier Debug instance was quit gracefully with explicit authorization. A new
Debug instance was built and launched, its panel detached, and Live sampled at **5 s**.
Docker Desktop was initially unavailable; this worker started it and confirmed connectivity.

Starting settings, preserved except for temporarily enabling Docker monitoring:

| Setting | Starting state |
|---|---|
| Sample duration / Live interval | 10 s / 5 s |
| Launch at login | Off; unavailable for this build |
| Hardware sensors | On |
| Docker containers | Off; temporarily turned on |
| Keep history / retention | Off / 7 days; Nothing saved |
| Offer Force Quit / Allow stopping a container | Off / Off; container switch verified after enabling Docker |
| Alert when the Mac runs hot | Off |
| Alert while Live runs | On; all five rule switches on |
| Live alert thresholds | CPU 60%; memory 90%; swap 2 GB; thermal serious; 6 containers |
| Global hotkey | On |

### Run 1 steps and workload

1. Created two scratch-only Compose overrides. Configuration inspection confirmed that
   each database had only its designated host port, **54401** or **54402**, and a separate
   project-scoped volume. Compose supported `!override`; no fallback was needed.
2. Held one machine-wide Docker-suite lock around the concurrent scenario. Created two
   Terminal tabs, each in its own new window, and ran the brief's database-start-and-test
   command from FDA with the prescribed synthetic agent names and isolated database URL.
3. Both commands started at **13:15:07 AEDT**, within the same recorded second. Both test
   runners started at **13:15:09**. Each reported **102 passed, 1 failed**: a database-role
   permission error. No FDA repair was attempted.
4. Test durations were **10.03 s** and **9.90 s**, so both were repeated in the same tabs.
   Both repeat commands started at **13:15:57** and both test runners at **13:15:58**.
   Each repeat passed **103 tests in 14 files**, in **7.40 s** and **7.51 s** respectively.
5. Captured app-window screenshots and accessibility text during both pairs, then expanded
   FDA in Projects and inspected Timeline. All raw evidence remains local in scratch.

### What Live showed in Run 1

| Card | Observed result |
|---|---|
| Projects | FDA appeared with container CPU included and Docker memory shown separately. Expanding FDA showed repository attribution with **“High confidence”**, process groups, and both temporary database containers, each supported by a **“Compose working_dir label”**. A separate Docker VM row remained visible. This confidence describes project attribution, not a concurrency explanation. |
| Timeline | Both container starts were attributed to FDA. Each pair produced two **“vitest started · FDA”** events and **“2 expensive commands at once: vitest (FDA), vitest (FDA) · FDA”**, labelled **“inference”**. After the repeat it also showed **“vitest started 4 times in 10 minutes in FDA (likely repeated runs) · FDA”**, likewise labelled inference. The chart displayed dashed inference markers and a busiest moment at **13:16:05, 98% of all cores**, with FDA among its contributing rows. |
| What's going on | **Absent throughout the captured runs.** Explanation title: not shown. Explanation confidence: not shown. Observations: not shown. Recommendation: not shown. No verbatim explanation or recommendation is available; an expected string from a unit test would not be an observation of this run. |
| Alert banner | At Live update 13, the banner read **“Swap above 2 GB for 1 minute”**. The same title entered Timeline. Swap was already above the threshold before the tests; this is not evidence that the test pair caused that condition. No other alert banner was observed in the captured run. |
| Heat and power wording | Thermal state remained a system-level reading. The inspected UI used CPU load and CPU energy labels; no per-process heat claim was observed. |

### Run 1 pass/fail and interpretation

| Exit requirement | Result |
|---|---|
| Attribute both containers and test activity to FDA | **Pass** |
| Show test concurrency and container starts in Timeline | **Pass** |
| Explain the burst as two agent trees, with confidence and non-destructive advice | **Fail: no card** |
| Avoid claiming per-process heat | **Pass in the inspected UI** |
| Clean up the isolated workload and restore settings | **Pass** |
| Overall Phase 3 exit (Run 1) | **Not met**; superseded by Run 2 |

The local process samples from the repeat showed test runners beneath the package manager
and ordinary shell scripts, without the prescribed synthetic agent identities surviving
in those ancestor chains. **Likely explanation, not a proven engine defect:** the launch
shell replaced the synthetic agent process with the final test command. The concurrency
rules require distinct agent trees or distinct projects; two unrecognised trees in FDA
can therefore produce Timeline concurrency without an explanation. A follow-up should
establish that both agent ancestors remain alive during sampling, then repeat the exit
check. This verification did not alter the prescribed workload to manufacture a passing card.
**Run 2 confirmed this:** with the stand-in agents kept alive as ancestors, the card appeared.

### Run 1 cleanup

- Removed only the two temporary Compose projects, including their containers, volumes and
  networks. Both project-filtered container queries returned no IDs before Docker was quit.
- FDA's Git status was identical before and after: one pre-existing workflow metadata edit.
  No FDA source or configuration file was edited by this worker.
- Paused Live, restored Docker monitoring to off, and verified all settings switches matched
  their starting values. The complete saved preferences also matched after removing an
  explicitly stored default interval introduced during setup.
- Quit the worker's HeatLens instance gracefully; the process check returned no HeatLens
  processes. The user's earlier instance was not relaunched.
- Asked Docker Desktop to quit because this worker had started it. (Run 2 later found the app
  still running with its VM unreachable, so the quit had not completed.) Closed only the two Terminal
  windows created for the scenario; left the pre-existing Terminal window alone.
- No HeatLens process-stop, Force Quit or container-stop control was used. No user container
  or volume was targeted. All workload scripts and capture helpers finished; the lock released.

## Run 2 (exit run)

### Preparation

- Built and launched a new Debug instance; no other HeatLens instance was running. Detached the
  panel, opened Live and started it at **5 s**.
- Starting settings were the same as Run 1's (table above). Only **Docker containers** was turned
  on. "Allow stopping a container" and Force Quit stayed off, and no stop control was used.
- Docker Desktop was running but its daemon answered every request with an error: the VM had
  gone idle and was unreachable, left over from Run 1's quit. Opening it again didn't help for
  several minutes, so this worker quit it cleanly, started it with `open -a Docker`, and the
  daemon answered after about 20 s.
- Wrote two scratch-only Compose overrides. `docker compose … config` confirmed each database
  published only **54401** or **54402**, with its own project-scoped volume. `!override` worked.
- Both runs were held under the machine-wide Docker lock.

### Steps and workload

1. Ran each stand-in agent in its own new Terminal window, from FDA, with the brief's command.
   `exec -a claude` / `exec -a codex` names the parent bash, and the trailing
   `; rc=$?; sleep 15; exit $rc` keeps it alive as the test's ancestor.
2. **Harness check (passed both times).** While the tests ran, a poller sampled `ps` every 2 s.
   Both stand-in parents were present, and each test runner's parent chain reached its own
   agent: test runner → package manager → `claude` or `codex`.
   - First pair: test runners 90347 and 90351 under agents 90031 and 90034.
   - Second pair: test runners 19389 and 19391 under agents 19062 and 19077.
3. **First pair:** both agents started at **13:35:19**, and both test runners at **13:35:21**.
   Each run took about 12 s and reported **109 passed, 1 failed**: a migration needed a database
   role permission the fresh database lacked. FDA was not touched.
4. The first pair's card included unrelated work (below). To get a clean capture of the card and
   the container starts, this worker removed only the two demo projects (`down -v`) and ran the
   pair again on fresh databases.
5. **Second pair (the exit capture):** both agents started at **13:37:19**, and both test runners
   at **13:37:20**. Runs took 11.3 s and 10.9 s, with the same **109 passed, 1 failed**.
   Each run lasted over 10 s, so no extra repeat was needed.

### What Live showed

| Card | Observed result |
|---|---|
| What's going on | **Second pair:** title **"2 test runs began within 10 s across 2 agent trees (claude, codex) in FDA, plus 2 containers"**, **High confidence**, labelled **inference**, "Started 1:37 PM · still running", later "ended 1:38 PM". Recommendation, verbatim: **"These test runs compete for the same CPU cores and the Docker VM. Run them one at a time, or have the agents take turns."** Observations: "1:37:20 PM vitest started · PID 19389, in FDA, under claude (PID 19062)"; "1:37:20 PM vitest started · PID 19391, in FDA, under codex (PID 19077)"; "1:37:23 PM Container heatlens-demo-a-db-1 started · in FDA"; "1:37:23 PM Container heatlens-demo-b-db-1 started · in FDA". Uncertainty lines: "HeatLens sees when these started and what started them, not how much heat or power each one causes." and "A container's start time is when HeatLens first saw it running, up to one refresh late." The card has no buttons. |
| What's going on, first pair | **"4 expensive commands began within 10 s across 3 agent trees (claude, codex) in FDA, plus 2 containers"**, **High confidence**, with the same recommendation in its "expensive commands" wording. Two of its four commands were type-check runs (`tsc`) from a real coding-agent session already working in FDA. The card was right to count that session: it was a third agent tree competing for the same cores. It kept both explanations, newest first. |
| Projects | FDA's row was present: "from git repository, High confidence". Expanded, it listed process groups (project processes and agent groups) and both demo containers, **heatlens-demo-a-db-1** and **heatlens-demo-b-db-1**, each "from Compose working_dir label". Container CPU was included in FDA and Docker memory shown separately; a separate Docker VM row remained. FDA peaked at **625%** CPU during the first pair. |
| Timeline | Second pair, in order: "heatlens-demo-a-db-1 started · FDA", "vitest started · FDA" twice, **"2 expensive commands at once: vitest (FDA), vitest (FDA) · FDA"** (inference), then the explanation's own event, **"2 test runs began within 10 s across 2 agent trees (claude, codex) in FDA, plus 2 containers · FDA"** (inference). The first pair produced the matching events, including "3 expensive commands at once: tsc (FDA), vitest (FDA), vitest (FDA) · FDA" and "vitest started 3 times in 10 minutes in FDA (likely repeated runs)". The chart showed dashed inference markers and "Busiest moment 1:35:33 PM · 100% of all cores", with FDA first among the contributing projects. |
| Alert banner | None was visible in any capture, although Live alerts were on and swap stayed above the 2 GB threshold. This run doesn't show why. |
| Heat and power wording | Heat stayed system-level (thermal state "Nominal"). Per-process and per-project figures were CPU and CPU energy, and the explanation states it can't attribute heat or power per process. No per-process heat claim was seen. |

### Findings

- **Title names agents, not trees.** The first pair's title says "3 agent trees (claude, codex)":
  the names are de-duplicated, so two separate `claude` trees appear once. It's accurate but
  reads as a miscount. Consider "(claude ×2, codex)".
- **Timeline shows the newest 6 events only.** During a burst, container-start events scroll
  out quickly. In the second pair, demo-b's start had already left the list. It stays in the
  explanation's observations and in the chart markers.
- **Real background activity joins bursts.** Another agent's work in the same project (type
  checks, a browser test run, and its own database container starting) was attributed to FDA,
  and was folded in correctly when it fell inside the 10 s window.

### Run 2 pass/fail

| Exit requirement | Result |
|---|---|
| Attribute both containers and test activity to FDA | **Pass** |
| Show test concurrency and container starts in Timeline | **Pass** |
| Explain the burst as two agent trees, with confidence and non-destructive advice | **Pass**: High confidence; take-turns recommendation, no stop action |
| Avoid claiming per-process heat | **Pass in the inspected UI** |
| Clean up the isolated workload and restore settings | **Pass** (Docker Desktop left running; see cleanup) |
| **Overall Phase 3 exit** | **Met** |

### Run 2 cleanup

- Removed only the two demo Compose projects with `down -v`. Project-filtered container queries
  for both returned no IDs, and no demo volumes or networks remain.
- Paused Live, turned Docker monitoring back off, and checked that every Settings switch and
  the saved preferences matched their starting values. Quit HeatLens; no HeatLens process
  remains.
- Closed only the four Terminal windows this worker opened; left the existing window alone.
- **Docker Desktop was left running.** This worker restarted it, but during the run another
  agent working in FDA started FDA's own database container on it. Quitting Docker would have
  stopped that container, which this worker must not touch.
- FDA's working tree gained two entries during the run: a new browser-test spec and Next.js's
  generated type file. Both came from the other agent's concurrent work in FDA: they were written
  at 13:37:46 and 13:38:42, after this worker's tests had ended, and the database tests write
  neither. No FDA file was edited by this worker.

## Not done or not verified

- **One machine, one shape.** The card was checked for two agent trees in one project. Two
  projects without agents, unplaced commands (medium confidence) and container-only bursts
  (low confidence) are covered only by unit tests.
- **Alert banners** didn't appear in Run 2 despite swap above the threshold. Hysteresis,
  cooldown and notification delivery weren't checked.
- **No Activity Monitor comparison.** The scan-result safe-action flows (stop, force quit,
  container stop), action records, exclusion changes, release builds, background operation
  and long sessions weren't exercised here.
- **Whole-system figures** (CPU peak, swap) mix this scenario with other activity on the Mac,
  so they can't be credited to the test runs alone.
- **Raw evidence stays local.** Screenshots, process samples and test logs contain machine
  data, so they're kept in the worker's scratch folder and left out of this report.
