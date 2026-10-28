# HeatLens performance (FR-12)

Measured on 2026-10-26 on the development Mac (Apple Silicon, macOS 14+ target). Every number
below has the command that produced it. Numbers vary between runs and machines. They are
measurements, not promises (PRD §5).

## 1. App idle, before any scan

Debug build, launched with `scripts/run-app.sh`. The popover was never opened and Scan now was
never clicked. The PID came from `pgrep -nf "HeatLens.app/Contents/MacOS/HeatLens"`, and the
measurements were taken with:

```
ps -o %cpu=,rss=,time= -p <pid>
top -l 1 -pid <pid> -stats pid,cpu,mem,idlew
```

| Time after launch | %CPU | RSS (`ps`) | CPU time (`ps`) | `top` MEM | `top` idle wakeups |
|---|---|---|---|---|---|
| about 30 s | 0.0 | 86,032 KB | 0:00.21 | 18M | 0 |
| about 60 s | 0.0 | 72,208 KB | 0:00.21 | 18M | 0 |

1. CPU time did not change between the two samples (0:00.21 both times), so the app did no
   work while idle.
2. RSS is higher than the PRD's 50 MB aim and falls over time as macOS compresses an idle app.
   `top`'s 18M memory figure is the closer measure of the app's own footprint, and it is under
   50 MB. Phase 0b recorded the same split (RSS 24 MB then 6.6 MB, `top` 18M).
3. The app has no timers or polling: `grep -rnE "Timer|DispatchSource" App` finds nothing. The
   only work is a scan the user starts.
4. The app was stopped afterwards with `kill -TERM <pid>` (the process this session had
   launched), and `pgrep -fl "HeatLens.app/Contents/MacOS"` then printed nothing.
5. **Thermal alert** (opt-in, off by default; 2026-10-27): idle cost doesn't change. While the
   setting is on, the app holds one `ProcessInfo.thermalStateDidChangeNotification` observer and
   no timer. Work happens only when macOS reports a rise into serious or critical: one normal
   scan (section 2), at most every 30 minutes. With the setting off there is no observer at all.

## 2. Scan cost

The scan engine without the UI, release build, default 5 s sample interval, three runs:

```
/usr/bin/time -l swift run -c release heatlens-probe --report --no-fixtures 2>&1 >/dev/null
```

| Run | Wall | User CPU | System CPU | Max RSS | Peak memory footprint |
|---|---|---|---|---|---|
| 1 | 7.14 s | 1.10 s | 0.15 s | 21.3 MB | 13.6 MB |
| 2 | 6.61 s | 1.12 s | 0.11 s | 21.3 MB | 13.6 MB |
| 3 | 6.59 s | 1.09 s | 0.13 s | 22.0 MB | 14.3 MB |

1. Wall time is mostly the 5 s sample interval. The rest (about 1.6 s) is `swift run` start-up,
   the two `ps` runs, `pmset`, the first and second process listing, and rendering the report.
   This command does not separate those parts.
2. About 1.2 s of CPU per scan is spent in total across the whole scan, spread over the sample
   interval. That is under 25% of one core on average.
3. The probe's footprint is not the app's. The app adds SwiftUI and AppKit.
4. `swift run` adds SwiftPM's own start-up to these figures. Timing the built binary directly
   (`/usr/bin/time -l .build/arm64-apple-macosx/release/heatlens-probe --report --no-fixtures`,
   two runs) gave 6.02–6.04 s wall, 0.96 s user + 0.07–0.08 s system CPU, 21 MB max RSS and
   13.5 MB peak footprint: about 1.0 s of CPU per 5 s scan.

5. **Listening ports** (2026-10-27): reading every readable process's TCP listeners once, at
   the end of the scan, took 3.4–9.3 ms for about 690 processes in the release build (3 runs) and
   11–22 ms in the debug build (2 runs). That is well under the 150 ms limit, so the work is not
   capped. Measured with `.build/release/heatlens-probe --no-fixtures --duration 1`, which times
   the same read on its own (its `port sampling:` line).

6. **Power assertions** (2026-10-27): one `IOPMCopyAssertionsByProcess` call plus filtering, at
   the end of the scan, took 0.44–0.59 ms for about 700 processes in the release build (4 runs)
   and 0.57–0.58 ms in the debug build (2 runs). Nothing is capped. Measured with
   `.build/release/heatlens-probe --no-fixtures --duration 1` (its `power assertion sampling:` line).

7. **Report cost fix** (2026-10-27, PRD-v2 brief 1a): the text report spent about 1.1 s of CPU
   compiling regular expressions. `String.range(of:options: .regularExpression)` compiles its
   pattern on every call, and the credential check called it for every path component. The app
   built a text and a JSON report after every scan, so it paid that twice. The patterns are now
   compiled once (`RedactionPatterns`). Release build, about 810 processes, three runs each:

   | Command | Before (user CPU) | After (user CPU) |
   |---|---|---|
   | `.build/release/heatlens-probe --report --no-fixtures --duration 1` | 1.21 s | 0.11 s |
   | `.build/release/heatlens-probe --report --no-fixtures` (5 s) | 1.20–1.22 s, 6.28–6.56 s wall, 15.1–15.7 MB peak | 0.11 s, 5.17 s wall, 13.3 MB peak |

   `RedactorTests` "Both reports for 1,000 processes…" keeps both reports for 1,000 synthetic
   processes under 1 s in a debug build (0.29 s measured).

8. **Live mode** (2026-10-27, PRD-v2 brief 1e; budget in docs/v2/ADR-0003: ≤ 2% of one core at
   5 s, < 30 MB footprint growth over 15 minutes). Release build, 5 s interval, hardware sensors
   and Docker on (one running container), about 800–850 processes. The 15-minute run was on battery:

   | Command | Wall | CPU (user + sys) | Average | Per tick | Peak footprint |
   |---|---|---|---|---|---|
   | `/usr/bin/time -l .build/release/heatlens-probe --live 60 --interval 5` | 64.0 s | 0.65 s | 1.0% of one core | median 89.8 ms, max 108.6 ms (13 ticks) | 10.7 MB |
   | `/usr/bin/time -l .build/release/heatlens-probe --live 900 --interval 5` | 900.9 s | 9.11 s | 1.0% of one core | median 93.3 ms, max 247.9 ms (174 ticks) | 19.4 MB |

   1. Both are within budget: footprint grew about 9 MB between the 1-minute and 15-minute runs.
      The trend ring stops growing at 150 ticks (12.5 minutes).
   2. The session auto-paused at 900 s as designed (`auto-paused after 900 s`).
   3. In the Debug app with the Live view open, `ps -o time=` 30 s apart grew 0.59 s (2.0% of
      one core, SwiftUI included). After the panel closed, it didn't grow at all in 30 s
      (docs/CLICKTHROUGH.md L4, L8).
   4. A tick's per-tick wall time includes the Docker socket round trips (about 15 ms) and the
      SMC read (about 15 ms). The rest is the process list, grouping and the trend ring.
   5. Per-process CPU energy (brief 1h) reads `proc_pid_rusage` v6 instead of v4: the same call,
      a larger struct. Re-measured with energy on: `--live 60 --interval 5`, 62.8 s wall, 0.61 s
      CPU (1.0% of one core), median tick 85.5 ms, max 97.6 ms. No measurable change.
   6. With the per-project breakdown (briefs 2a/2b): `--live 60 --interval 5`, 63.4 s wall, 0.73 s
      CPU (1.15% of one core), median tick 97.4 ms, max 114.7 ms, max RSS 18.2 MB. The breakdown
      itself is under 50 ms for 1,000 processes in 300 groups (a test); repository roots are
      cached, so only new folders cost stats.
   7. With the timeline and expensive-command detection (briefs 2d/2e): two runs of
      `--live 60 --interval 5`: 0.78 s and 0.72 s CPU in 64 s (1.1–1.2% of one core), median tick
      96–101 ms. Detection on 1,000 processes is under 10 ms per tick (a test), because each
      process is classified once. History writes are under 0.1 ms per tick (ADR-0005).

9. **Adaptive sampling** (2026-10-28, PRD-v2 brief 4a; budgets in docs/v2/ADR-0008 §6: ≤ 0.3% of
   one core idle on power, ≤ 0.1% in Low Power Mode, ≤ 2% during an incident). Release build,
   `--background` runs an adaptive session with nobody looking, hardware sensors and Docker on,
   about 800 processes, on power. Other builds and test runs were going on the same Mac during
   both runs (host 37–100% busy, median 60%).

   | Command | Wall | CPU (user + sys) | Average | Intervals | Per tick | Peak footprint |
   |---|---|---|---|---|---|---|
   | `/usr/bin/time -l .build/release/heatlens-probe --background 900` | 904.6 s | 11.21 s | 1.24% of one core | all 173 planned 5 s (incident); median span 5.2 s | median 104.7 ms, max 1,513 ms | 20.6 MB |
   | `/usr/bin/time -l .build/release/heatlens-probe --background 400 --assume-low-power` | 426.3 s | 0.32 s | 0.075% of one core | all 4 planned 120 s (Low Power Mode); median span 127.3 s | median 106.2 ms, max 163.6 ms | 12.4 MB |

   1. **The idle-on-power target was not measured.** The Mac was never idle: half the ticks had
      all cores at least 60% busy, and the run saw 24 expensive-command and 8 test-run starts.
      Each of those is an incident trigger, so every interval was the incident cadence (5 s on
      power). That run does show the incident case, and it is within its ≤ 2% budget.
      Per-tick CPU there was about 65 ms (11.21 s / 173 ticks). At 30 s that would be about 0.22%
      of one core, but that is an extrapolation, not a measurement. To measure it, run the
      900 s command again on a quiet Mac: the summary line should read `reasons idle …` with a
      median span near 30 s.
   2. Low Power Mode is within its ≤ 0.1% budget, and it stayed at 120 s while the Mac was busy:
      Low Power Mode is never fast.
   3. Spans run longer than planned: 5.1–5.5 s for 5 s, and 126.7–128.2 s for 120 s.
      `Task.sleep` lets macOS add slack to long timers so it can wake less often (about 6% at
      120 s here), and the span also includes the tick's own collection time. The sleep check
      (a span over 3× the plan resets alert timers) has plenty of room for both.
   4. The 1.5 s tick in the 900 s run is a single outlier. It came while the other work kept
      the cores busy, and this run doesn't show what caused it. The next-slowest tick took
      522 ms.

## 3. Snapshot cost

No test or probe output prints the cost of building a snapshot, rules and report on their own,
so it is not reported separately. Section 2 is the only end-to-end figure.

## 4. Not measured

1. **App idle after a real scan.** It needs a click on Scan now in the running app. Phase 1b
   noted the same gap. Check it by clicking Scan now, waiting for results, then running the two
   commands from section 1 twice, 30 s apart. CPU time should not grow.
2. **Memory while a scan is running inside the app.** Only the probe was measured (section 2).
3. **Release build of the app.** Section 1 used the Debug build that `scripts/run-app.sh` makes.
4. **Machines other than this one**, and Intel Macs (not a target).
