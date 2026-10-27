# HeatLens v2 — Phase 2 report

Date 2026-10-28. Machine: MacBook Pro M3 Pro (Mac15,6), macOS 27.0.1, Docker Desktop 28.5.1.
Plan: [PLAN.md](PLAN.md). Phase 1: [PHASE-1-REPORT.md](PHASE-1-REPORT.md).

**Exit (PRD-v2):** "a user can navigate from a CPU spike to a named repository, contributing
process tree and supporting timeline evidence." In Live mode, the Timeline card names the busiest
moment, the projects busiest then and the events just before it. The Projects card opens each
repository to its process groups and containers, and process detail names the repository.

## Changelog

- **2a, project attribution** ([ADR-0004](ADR-0004-project-attribution.md)):
  - `ProjectRootLocator` finds the nearest `.git`, else a manifest, above a process's folder. It
    only checks whether files exist (`fstatat`) and skips privacy-protected folders, other
    volumes and network mounts. It caches results.
  - "Project folders" in Settings maps a folder to a project name.
  - Containers are tied to projects by a user mapping, the Compose `working_dir` label, the
    `config_files` folder, or bind mounts into one project. Anything else is Unattributed, with
    the reason. The mounts come from the container list, so there is **no new Docker endpoint**.
- **2b, per-project totals:** `ProjectAttributor.breakdown`.
  - Rows: per project, then Docker VM, then Unattributed.
  - Container CPU is *moved* from Docker's VM process to its project, so the rows add up to the
    host's CPU. Container memory is shown, never added.
  - The Projects card appears in Live and in scan results.
- **2c, history** ([ADR-0005](ADR-0005-history-store.md)): `HistoryStore` over the system SQLite.
  - "Keep history" is off by default. Only Live writes, once per tick.
  - Raw ticks are kept for an hour, then one row per minute. Retention is 1, 7 or 30 days.
  - Settings has Delete history. The file is owner-only and symlinks are refused.
- **2d, timeline:** the session timeline is kept in memory. With history on, "1 hour" and
  "24 hours" read the saved history. A Swift Charts CPU line shows event markers (inferences
  dashed), the busiest moment and recent events.
- **2e, expensive commands** (`ExpensiveCommand`, `TimelineDetector`):
  - Recognised: installs (`npm ci`, `pnpm install`, …), builds (`next build`, `vite build`, `tsc`,
    `docker build`, `cargo`/`swift`/`go build`, `xcodebuild`, Gradle) and test runs (`vitest`,
    `jest`, `pytest`, `playwright test`, `npm test`, …).
  - Only the outermost command of a tree counts.
  - Events: started; several at once (when the set grows); started 3 times in 10 minutes in one
    project. Thermal changes and container starts and stops are events too.
  - "At once" and "repeated" are labelled as inference.

## Tests

`swift build && swift test`: **293 tests in 51 suites, all passing** (257 in 41 after Phase 1).
`scripts/run-app.sh --build-only`: builds.

| Suite (new) | Tests | Covers |
|---|---|---|
| Project roots (stat only) | 6 | `.git` beats a nearer manifest; manifest fallback; never at or above home; protected folders and volumes never stat'ed; cache and expiry; this checkout |
| Project attribution | 5 | mappings parse; mapping > repository > folder; FDA container → `~/Developer/FDA`; config_files, bind mounts, split mounts, bare Compose; mapping beats Compose |
| Per-project breakdown (+ scale) | 7 | rows add up to the host total; over-attribution clamps at 0; no VM; two VMs; Docker off; 1,000 processes in 300 groups < 50 ms |
| Project attribution against this Mac | 1 | running Compose containers get a real root |
| History store | 7 | permissions and symlinks; round trip with bound values; minute rollups; retention; 7-day bound; per-tick cost; delete |
| Expensive commands | 3 | recognised commands, non-matches, outermost only |
| Timeline events (+ scale) | 5 | baseline; started, containers, thermal; concurrency; repeats; 1,000 processes < 10 ms |
| Timeline analysis | 1 | peak, projects at the peak, events before it |
| Live monitor (+2) | | history only from ticks; events in tick, session timeline and history |

## Validation on this Mac

| Check | Result |
|---|---|
| Live probe with Docker on | Every tick listed `FDA … (1 containers)` from the Compose label and `.git`, plus other running projects by repository folder |
| Live probe while two placeholder commands start (`exec -a "npm ci"`, `exec -a vitest`) | `npm ci started`, `vitest started`, then "2 expensive commands at once: npm ci (…), vitest (…) (inference)", attributed to this repository |
| Live cost at 5 s, release engine, 60 s, everything on | 0.78 s and 0.72 s CPU in 64 s: **1.1–1.2% of one core** (1.0% after Phase 1); median tick 96–101 ms; max RSS 19 MB |
| History, worst case | 7 days of minute rows with 10 projects: 6.5 MB |

## Not done or not verified

- **The new cards weren't driven in the app.** The Mac's display was asleep or locked during the
  click-through, so the Projects and Timeline cards and the history settings are built and
  unit-tested but not yet seen on screen. A click-through is the first task of Phase 3.
- Projects aren't in the copied reports or the CLI/MCP output yet.
- The timeline looks back further than the session only while "Keep history" is on, and only over
  periods when Live was running (Live pauses after 15 minutes; background sampling is Phase 4).

## Open decisions for the owner

1. Should "Keep history" stay off by default? It writes to disk, which v1 promised not to do.
2. Should projects (names, not paths) go into the copied report and the MCP output for Jarvis?

## Next: Phase 3 brief

**Goal:** explanations, alerts and safe actions; exit: reproduce the FDA multi-worker Docker
test scenario and get a useful, non-destructive explanation.

1. **3a Click-through** of Phase 2 in the app (Projects, Timeline, history settings).
2. **3b Concurrency rules** as findings, built on 2e's events: "three Docker integration tests began
   within 10 s across two agent trees" (group the agent tree with `ProcessTree`).
3. **3c Alert policies** with hysteresis and cooldown (CPU, thermal, swap, memory, containers).
4. **3d Safe actions** (new ADRs and security review first): force quit after a separate
   confirmation; stopping one selected container (the first non-GET Docker call).
5. **3e Local audit trail** of suggested and executed actions; ignore a process or project.
