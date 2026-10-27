# ADR-0003: Live monitoring runs in-process, only while the user is watching; no local server

- **Status:** Accepted for Phase 1 (2026-10-27)
- **Context:** PRD-v2 §5 (collector ↔ UI transport), §6 Phase 1 exit ("live dashboard with refresh
  controls, low-overhead sampling"), §9 (budgets); PRD v1 §5 (no continuous polling)

## Decision

1. **Transport: none.** The collector (`HeatLensCore`) and the UI are one native process, as they
   are today. There is no localhost port, no XPC service and no web UI to authenticate. That
   removes PRD-v2 §5's whole class of origin, CSRF and loopback-binding risks. The existing
   `heatlens mcp` server uses stdio and stays the only agent-facing surface. It has no listener.
2. **`LiveMonitor` actor** in `HeatLensCore`: `start(interval:)` returns an `AsyncStream<LiveTick>`,
   and `stop()` ends it. Each tick reads host CPU ticks, the libproc process list, memory and
   thermal state, and, when enabled, hardware sensors and Docker. It computes CPU deltas against
   the previous tick with the same `ScanAssembly`/`CPUMath` code as a scan. A one-off scan and a
   live tick therefore always agree on what 100 % means.
3. **When it runs:** only between the user pressing **Start live** in the panel and any of
   Pause, closing the panel, quitting, or a 15-minute auto-pause. Opening the panel does not start it.
   The idle app keeps ~0 % CPU and no timers.
4. **Refresh controls:** an interval of 2, 5 (default) or 10 s, **Pause/Resume**, and **Refresh now**.
   There is no interval under 2 s.
5. **Per-tick work is cheaper than a scan:** no `ps` fallback (root-process CPU is marked
   "not sampled in live mode", and "Scan now" gives it), no report building, no port or
   power-assertion reading. Provenance grouping runs every tick only if it fits the budget
   below. Otherwise it runs every Nth tick.
6. **Memory:** a ring buffer of the last 150 ticks (12.5 min at 5 s) holds per-process CPU and
   memory, for trend sparklines. It is in memory only, as "Since last scan" is today, and is dropped on stop.
   Persistence is Phase 2's history store.
7. **Budget (to be measured in brief 1d; this is the target):** at a 5 s interval, live mode
   averages **≤ 2 % of one core**, with **< 30 MB** footprint growth over 15 minutes. A tick
   that takes longer than its interval skips the next one rather than queueing.

## Why not

- **A background daemon or LaunchAgent now:** PRD-v2 puts it in Phase 4, with a signed helper,
  an uninstaller and its own overhead budget. Phase 1 must not change the app's idle footprint.
- **A localhost HTTP server, like `macmon serve`:** that is the exact risk PRD-v2 §5 and §8 warn
  about, and it would buy nothing while the UI is in-process.
- **Re-running the full scan in a loop:** a scan costs ~1.2 s CPU (`GAP-ANALYSIS.md` §4) and
  includes `ps`, ports and assertions. A loop of those would be the resource hog PRD v1 forbids.

## Consequences

- Live mode can't show root-process CPU. The UI says so, with a "Scan now" shortcut.
- Phase 2's history store will hang off the same `LiveTick` stream, so it needs no new collector.
- Phase 4's background helper, if built, would reuse `LiveMonitor` inside a LaunchAgent and speak
  to the UI over XPC, never TCP. That needs a new ADR.
