# ADR-0005: Local history in the system SQLite, off by default, written only from live ticks

- **Status:** Accepted for Phase 2 (2026-10-28)
- **Context:** PRD-v2 §6 Phase 2 ("maintain local bounded time series … short high-resolution
  window plus rolled-up history, with configurable retention and deletion"); PRD-v2 §8.

## Decision

1. **Storage:** `HistoryStore`, an actor over the SQLite that ships with macOS (`import SQLite3`,
   `libsqlite3`). No package dependency.
2. **Off by default.** Settings → "Keep history". Nothing opens or creates the file until the
   switch is on *and* a live session starts. Only `LiveMonitor` writes, once per tick, inside
   a session. Scans, the CLI and the MCP server never write.
3. **Shape:**
   - `samples`: one row per tick (thermal state, host load and its peak, swap, memory pressure,
     CPU temperature, system power, process CPU energy).
   - `project_samples`: the 8 busiest projects per tick (CPU, memory, energy), keyed to a
     `projects` table (folder and name), so the folder isn't repeated per row.
   - `events`: timeline events (brief 2d/2e): kind, a short title made of process, container
     and project names, the project name, and whether it is an inference.
4. **Bounded:** raw ticks for 1 hour, then one row per minute (load averaged, peaks and heat
   as maxima). Retention 1, 7 (default) or 30 days, applied at once when changed. Row caps behind
   retention (30 days of minutes, 20,000 events) are checked hourly.
5. **Delete history** in Settings closes the database and unlinks the file, its WAL and
   shared memory. Turning "Keep history" off stops writing but keeps the file until deleted.

## Security and privacy review

- **What's stored:** numbers, timestamps, project names and folder paths, container and process
  *names*. Never argv, environment, file contents, process IDs or anything from Docker beyond
  names. Titles are capped at 200 characters, names at 80.
- **Where:** `~/Library/Application Support/HeatLens/history.sqlite`. The folder is created
  `0700` and must be a real directory owned by the user (`lstat`); the file and WAL are `0600`.
  A symlink at the folder or the file is refused (`lstat`, then `SQLITE_OPEN_NOFOLLOW` on the
  resolved path), so another local process can't redirect writes.
- **SQL:** every value is bound with `sqlite3_bind_*`; table names are constants. A test stores
  `x'); DROP TABLE samples; --` as a title and reads it back unchanged.
- **Hardening pragmas:** `trusted_schema = OFF`, `secure_delete = ON` (deleted rows are
  zeroed), WAL with `synchronous = NORMAL`, incremental auto-vacuum.
- **No network, no sync, no export.** The file never leaves the Mac; reports don't include it.
- **Failure:** an open or write error is shown in Live ("History not saved: …"); sampling goes
  on. History is never required for anything else to work.

## Evidence (tests, this M3 Pro)

| Check | Result |
|---|---|
| An hour of 5 s ticks, 8 projects each | 720 ticks in 59 ms, under 0.1 ms per tick |
| 7 days of minute-by-minute ticks with 10 projects, maintenance every tick (worst case) | 6.5 MB on disk; 10,080 samples, 80,640 project rows, 336 events; 2.6 s |
| Two hours of 5 s ticks, then maintenance | 720 raw rows for the last hour, 60 minute rows (12 ticks each) before it |
| Retention | rows past 7 days dropped; switching to 1 day drops at once |
| Permissions | folder `0700`, file `0600`; symlinked file and folder refused |
| Live monitor | no rows before start or after stop; one per tick during a session |

## Options considered

| Option | Against |
|---|---|
| JSON files per hour | Rollups and pruning by hand, no atomic writes, larger. |
| Core Data / SwiftData | More machinery than a few tables need; schema in a model file. |
| A package (GRDB, SQLite.swift) | A dependency for about 300 lines of SQLite calls. |
| Always on | v1 promised "nothing is stored except settings"; the user opts in. |
