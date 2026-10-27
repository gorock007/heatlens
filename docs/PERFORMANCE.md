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
