# HeatLens feasibility (Phase 0a)

> Note: the probe has since become a thin CLI over `ScanCoordinator` (Phase 1.1); the sample output below is from the Phase 0 spike and its format differs from today's `heatlens-probe`.

Measured on 2026-10-26 on the target machine: MacBook Pro M3 Pro (Mac15,6, 11 cores = 5 P + 6 E,
18 GB), macOS 27.0.1 (26A434), Xcode 26.6 / SDK 26.5, Swift 6.3.3. Every claim below was
produced by `swift run heatlens-probe` (source in `Sources/heatlens-probe/`), run while the
usual workload was up: Claude Code (Superset terminals and the desktop app), OpenCode,
Superset, Docker Desktop, a `next dev` server, and CapCut decoding video. Nothing was started for
the test except two fixtures the probe spawns and stops itself (`yes >/dev/null` and a
launchd-adopted `sleep`), each bounded to 60 s.

Reproduce: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift run heatlens-probe`
(flags: `--duration <1…15>`, `--no-fixtures`, `--top <n>`). Numbers vary with load; the
availability pattern (which calls fail, with which errno) does not.

## Summary of decisions

1. **No C shim.** Every API needed (`proc_listallpids`, `proc_pidinfo` flavours, `proc_pidpath`,
   `proc_pid_rusage`, `sysctl`/`sysctlbyname`, `host_processor_info`, `host_statistics64`,
   `mach_timebase_info`) is reachable from Swift through `import Darwin`. Only the macro
   `PROC_PIDPATHINFO_MAXSIZE` is not importable (it is `4*MAXPATHLEN`; write the literal).
2. **Unsandboxed direct distribution is required**, as the PRD anticipated. Inside the App
   Sandbox the engine loses `proc_listallpids` (EPERM), `proc_pid_rusage` for everything but
   itself (so no physical footprint), and the ability to spawn `ps`; details for the current
   user's processes still work through `proc_pidinfo` + `sysctl KERN_PROC_ALL`. Section 7.
3. **Even unsandboxed, only the current user's processes expose detail.** `proc_pidinfo`
   (all flavours), `proc_pid_rusage` and `KERN_PROCARGS2` fail with EPERM / EINVAL for root and
   other-user processes. `proc_pidpath` and `sysctl KERN_PROC_ALL` (pid, ppid, uid, start time,
   16-char comm) work for all. This is the single biggest constraint: **`kernel_task`,
   `WindowServer` and all root daemons have no CPU or memory numbers from libproc.**
4. **Root-process CPU comes from a read-only `ps` fallback**, which the PRD allows. `/bin/ps`
   carries Apple's private `com.apple.system-task-ports.read` entitlement and reports cumulative
   CPU `TIME` (10 ms resolution) and RSS for root processes to an unprivileged caller. Two
   `ps -A -o pid=,time=` runs bracketing the interval give deltas for the ~200 processes
   libproc refuses. `ps` never lists pid 0; `top -l` does, but costs ~1 s per sample.
5. **CPU % convention verified**: 100 = one core. `pti_total_user/system` ticks are Mach
   absolute time (timebase 125/3 here, i.e. 24 MHz, *not* nanoseconds); divided by the
   `mach_absolute_time` delta they match `proc_pid_rusage`, `ps` and `top` (section 4).
6. **Identity = `(pid, pbi_start_tvsec/usec)`** from `proc_pidinfo(PROC_PIDTBSDINFO)`, equal to
   `kinfo_proc.p_starttime` for every process (agree 514 / differ 0), so the same identity is
   available for processes libproc refuses. `ri_proc_start_abstime` is a second, boot-monotonic
   key but only exists where rusage works.
7. **Thermal: `ProcessInfo.thermalState` is the only real source.** `pmset -g therm` on this
   machine prints three "no … recorded" notes and no limit values. No temperature anywhere.
8. **Memory pressure: `kern.memorystatus_vm_pressure_level` is live** (it flipped 1 → 2 while
   CapCut was decoding). Swap is large on this Mac (8.5 of 10 GB used) while pressure reads
   "normal", which is exactly the PRD's "RAM usage alone is not pressure" case.
9. **Deployment target macOS 14.0 stands.** Nothing here needs newer; see "Deployment target".

## Availability table

"Own" = processes of the current uid (≈ 510 of ≈ 715 here), "root" ≈ 120, "other" ≈ 75 (`_windowserver`, `_mdnsresponder`, …). Errnos are what the probe recorded.

| # | Field | API | Own | Root / other user | Caveats | Verified how |
|---|---|---|---|---|---|---|
| 1 | PID list | `proc_listallpids` | all | all | Includes pid 0 (`ps` omits it). Count matched `sysctl KERN_PROC_ALL` and `ps -A` exactly (786/786/786; 716/716/716). Fails with EPERM in the sandbox. | set difference vs `ps -A -o pid=` |
| 1b | PID list (fallback) | `sysctl {CTL_KERN, KERN_PROC, KERN_PROC_ALL}` | all | all | Works in and out of the sandbox; also yields ppid, uid, start time, 16-char comm for *every* process. | same |
| 2a | PPID, uid, start time, name | `proc_pidinfo(PROC_PIDTBSDINFO)` | ✅ 562/570 | ❌ EPERM(1) ×216 | Misses are ESRCH (process exited between list and read). `pbi_name` is longer than the 16-char `pbi_comm` for ~290 processes; prefer it. | counts per owner class |
| 2a′ | same, for refused pids | `kinfo_proc` from 1b | ✅ | ✅ | Start time identical to 2a for all 514 comparable processes. | field compare |
| 2b | Executable path | `proc_pidpath` | ✅ | ✅ 129/130, 86/86 | The one libproc call that works for everyone. One ENOENT (deleted binary). | counts |
| 2c | CPU time, RSS, threads | `proc_pidinfo(PROC_PIDTASKINFO)` | ✅ | ❌ EPERM | Ticks are Mach absolute time; convert with `mach_timebase_info` (125/3). | fixture + ps + top |
| 2d | CPU time, physical footprint, disk I/O, start abstime | `proc_pid_rusage(RUSAGE_INFO_V4)` | ✅ 569/570 | ❌ EPERM | Agrees with 2c to <2 points on every process. `ri_phys_footprint` is Activity Monitor's "Memory" column. Sandbox: self only. | compare 2c vs 2d |
| 2e | CPU time, RSS for root/other | `/bin/ps -A -o pid=,time=,rss=` (subprocess, no shell) | ✅ | ✅ 120/121 nonzero TIME | Cumulative; delta two runs. 10 ms resolution. Not pid 0. Cannot be spawned from a sandbox (EPERM at `posix_spawn`). | parsed output |
| 3a | argv | `sysctl KERN_PROCARGS2` + `ProcArgsParser` | ✅ 562/570 | ❌ EINVAL(22) | Rewritten titles come through (`next-server (v16.4.3)`). argv can carry prompt text (`opencode --prompt …`) → redact in exports. Environment follows argv in the buffer and is never decoded. | parsed for 549 processes |
| 3b | cwd | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | ✅ 562/570 | ❌ EPERM | Works in the sandbox for own processes. | counts |
| 4 | CPU % | 2c/2d deltas ÷ `mach_absolute_time` delta | ✅ | via 2e | `yes` fixture: probe 99.7 %, rusage 99.7 %, `ps %cpu` 99.5 %; under contention probe 67.6 % vs `top` 54–96 % per 2 s window. Snapshot of ~720 pids takes 2–4 ms. | section 4 |
| 5a | Total CPU load | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | ✅ | — | Per-core user/system/idle/nice ticks; sandbox OK. 11 entries; cores 0–5 and 6–10 behave as two clusters (E/P ordering not verified). | two snapshots |
| 5b | Memory pressure | `sysctlbyname("kern.memorystatus_vm_pressure_level")` | ✅ | — | 1 normal / 2 warning / 4 critical. Observed both 1 and 2. `kern.memorystatus_level` gives % available (32–46 observed). The dispatch memory-pressure source is event-only; not needed for a snapshot. | read |
| 5c | Swap | `sysctlbyname("vm.swapusage")` → `xsw_usage` | ✅ | — | 8.5 GB / 10 GB used, encrypted. | read |
| 5d | Compressed memory, page categories, swapins/outs | `host_statistics64(HOST_VM_INFO64)` | ✅ | — | Page counts × `hw.pagesize` (16384). Swap-out *delta* across the interval is the live signal; cumulative counts are since boot. | read |
| 6a | Thermal state | `ProcessInfo.processInfo.thermalState` | ✅ | — | `nominal` throughout; never fabricate more. | read |
| 6b | pmset | `/usr/bin/pmset -g therm` via `Process` + `PmsetThermParser` | ✅ exit 0 | — | On this M3 Pro: only "No thermal/performance warning level … recorded", "No CPU power status has been recorded". No `CPU_Speed_Limit` keys at all. Works in the sandbox. Treat as optional notes. | raw output |
| 7 | Sandbox | ad-hoc `codesign --entitlements` with `com.apple.security.app-sandbox` | see §7 | | A bare executable is killed at launch (SIGTRAP in `_libsecinit_appsandbox`); it must live in an `.app` bundle with a `CFBundleIdentifier`. | crash report + bundle run |
| 8 | Grouping | ppid chain + argv + cwd | ✅ | ppid chain only | Sufficient: see §8. | live run |

## 1. PID enumeration

`proc_listallpids(nil, 0)` returns the count; call again with a buffer plus headroom. Three
sources agreed exactly on every run (e.g. 786 / 786 / 786), differing only by pid 0 (libproc and
kinfo have it, `ps` does not) and by `ps` itself. Processes come and go during a 5 s scan
(8–14 vanished, 7–21 appeared), so the sampler must treat ESRCH as normal.

## 2. Per-process fields

For the current user everything works. For root and other users only `proc_pidpath` and the
`kinfo_proc` sysctl work; every `proc_pidinfo` flavour and `proc_pid_rusage` return EPERM.
`kernel_task` (pid 0) has nothing beyond `kinfo_proc` (comm, uid 0). Activity Monitor, `top` and
`ps` see more because they carry `com.apple.system-task-ports.read`, which third-party apps
cannot have. Consequence for the overview: the sum of per-process CPU covers only part of the
host load (2.6 of 5.2 busy cores in one run, 1.7 of 3.4 in another); the gap is root processes
plus processes that did not live through the whole interval. The UI must say so ("CPU for
system processes from `ps`, 10 ms resolution" or "not available") rather than let the user
infer that the visible processes explain all the heat.

## 3. argv and cwd

Both are readable for every own-user process (549/549 that survived the interval) and for none
of root's or another user's. argv findings worth keeping:

- Processes rewrite their title: the Next.js render server shows `argv = ["next-server (v16.4.3)"]`
  with no path; the project comes from its cwd or its parent (`node …/node_modules/.bin/next dev`).
- `claude` from nvm appears with `pbi_name = "claude.exe"` and a full `--model … --prompt …` argv;
  `opencode --prompt "You are a Jarvis worker …"` carries the whole prompt. Exports must redact
  argv beyond argv[0] and recognised flags by default (FR-11).
- `KERN_PROCARGS2` returns the environment after argv in the same buffer. `ProcArgsParser` stops
  at `argc` strings and never decodes it (PRD §4.1).

## 4. CPU %

Two snapshots of ~720 pids take 2–4 ms each; the interval is measured with `mach_absolute_time`.
`proc_taskinfo.pti_total_user/system` and `rusage_info_v4.ri_user_time/ri_system_time` are both
Mach absolute-time ticks; converted through the 125/3 timebase they agree within 2 points for
every process in every run. Cross-checks on the spawned `yes` fixture:

| run | probe (taskinfo) | probe (rusage) | `ps -o %cpu` | `top -l` |
|---|---|---|---|---|
| quiet 5 s | 99.7 % | 99.7 % | 99.5 % | — |
| 5 s | 97.7 % | 97.7 % | 98.4 % | — |
| 4 s under contention (CapCut + `top` running) | 67.6 % | 67.6 % | — | 53.7 / 75.9 / 95.9 % per 2 s window |

`ps %cpu` is a decaying average, not an interval measurement; `top` is interval-based but its
first sample is always 0 and the tool itself costs a core-second. Both agree with the probe
within their own error. A 10 s interval behaved identically (714 → 703 pids, 0 identity changes).

## 5. System

All four facilities worked, unsandboxed and sandboxed. Readings during the runs: host 28–47 %
of 11 cores busy; free 100–950 MB, wired 3.9–5.4 GB, compressed 5.4–6.5 GB of 18 GB; swap 8.5 /
10 GB; pressure level 1 (normal) in quiet runs and 2 (warning) while CapCut decoded; `kern.memorystatus_level`
32–46 %. For the findings engine: use the pressure level as the primary memory signal, swap-out
delta across the interval as corroboration, and show absolute swap only as context.

## 6. Thermal

`ProcessInfo.thermalState` read `nominal` throughout (the Mac was warm but not throttling).
`pmset -g therm` printed only:

```
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

so on Apple Silicon it is a source of *notes*, not numbers, unless the system has throttled since
boot. The parser keeps unknown lines as notes and reports `indicatesThrottling = nil` when no
limit keys exist. No temperature API is used; FR-08 is satisfied by the thermal state plus
"Unavailable" wording.

## 7. Sandbox cost

Method: the built probe was copied into a scratch `HeatLensProbe.app` bundle with a minimal
`Info.plist` and ad-hoc signed with `com.apple.security.app-sandbox`. A bare executable signed the
same way is killed by `libsystem_secinit` at launch (EXC_BREAKPOINT in `_libsecinit_appsandbox`),
so the sandbox can only be measured from a bundle. Inside the sandbox (`APP_SANDBOX_CONTAINER_ID`
set, home moved to `~/Library/Containers/…`):

| Facility | Unsandboxed | Sandboxed |
|---|---|---|
| `proc_listallpids` | ✅ | ❌ EPERM (returns 0) |
| `sysctl KERN_PROC_ALL` | ✅ | ✅ (enumeration still possible) |
| `proc_pidinfo` bsd/task/vnode, own processes | ✅ | ✅ 492/499 |
| `proc_pidinfo`, root/other | ❌ | ❌ |
| `proc_pid_rusage` | ✅ own | ❌ self only (no physical footprint, no disk I/O) |
| `proc_pidpath` | ✅ all | ✅ all |
| `KERN_PROCARGS2` own | ✅ | ✅ |
| spawn `/bin/ps` | ✅ | ❌ EPERM at `posix_spawn` (no root CPU at all) |
| spawn `/usr/bin/pmset` | ✅ | ✅ |
| `host_processor_info`, `host_statistics64`, swap, pressure sysctls, thermal state | ✅ | ✅ |
| `kill(SIGTERM)` own child | ✅ | ✅ |

A sandboxed build would therefore still show the user's own processes with CPU and RSS, but
lose footprint, lose every number for system processes, and have to enumerate via sysctl. That
is a materially worse product for the PRD's core question, so v1 ships unsandboxed, direct
distribution, as Jarvis decided. The Mac App Store is out for v1.

## 8. Real-world grouping

With the normal workload up, ancestry + argv + cwd were enough to tell the PRD's cases apart:

- **The PRD's incident, live:** `node ~/.superset/projects/<project-a>/scripts/worker.js`, PPID 1,
  2d 6h old, 0.2 % CPU, cwd = the project. Classified "node script: worker.js", project from
  cwd. It is one of 13 user-space PPID-1 candidates after dropping the ~340 launchd-started
  agents and Finder-launched apps that also have PPID 1 (filter: path under `/System`, `/usr`,
  `/Applications`, … and no project cwd). PPID 1 alone is useless as a signal; PPID 1 + project
  cwd + script argv is a good "review" candidate.
- **Next.js:** `npm run dev` (PPID 1, cwd `~/Developer/<project-b>`) → `node …/.bin/next dev` →
  `next-server (v16.4.3)` → turbopack worker `node …/.next/dev/build/chunks/pool_entry-[turbopack-node]…`.
  The root of the group is the `npm run dev` process; argv of the children names the tool, cwd
  names the project. 40 min old, 0 % CPU: "idle dev server, review".
- **Agents:** `claude` (name `claude.exe`, argv `claude --dangerously-skip-permissions --model …`)
  and `opencode …` each sit under `zsh → Superset → Superset → Superset(PPID 1)`, with cwd =
  the project they work in (`~/.superset/worktrees/…`, `~/Developer/<project-c>`); their MCP
  children (`npm exec convex@latest mcp start`, `uv … python …`) group under them by ancestry.
  The desktop Claude app's embedded Claude Code (`disclaimer → Claude → launchd`) is told apart
  from terminal Claude Code by its ancestry and by its path under `~/Library/Application Support/Claude/claude-code/`.
- **Superset / Docker / CapCut:** identified by executable path (`Superset.app`, `Docker.app`,
  `CapCut.app`); Docker's VM is `com.apple.Virtualization.VirtualMachine` under `com.docker.backend`
  with a 3 GB footprint. CapCut's decode work shows up as a separate `VTDecoderXPCService`
  process (0.9 GB, 23 % CPU) whose parent is launchd, not CapCut; attributing it needs a
  "same-app XPC service" rule (bundle path or responsible-pid), which Phase 1 should note as a
  limitation rather than solve.
- **Lessons for the resolver:** match argv *tokens*, not substrings (the spike's `"/bin/jarvis"`
  substring rule also matched this worker's own `zsh -c source … jarvis leftovers` shells);
  `node` as an executable name is weak (Raycast ships its own `node`); cwd is the best project
  evidence (549/549 own processes had one), argv path second; and walking up to a project root
  (first ancestor dir containing `package.json`/`.git`) needs only `stat`, never file contents,
  which stays within PRD §4.1 if done at all.

## Sample output (redacted, final run, 5 s)

```
heatlens-probe · 2026-10-26 · sample 5.0s
macOS Version 27.0.1 (Build 26A434) · Mac15,6 · Apple M3 Pro · 11 cores (P 5 / E 6) · RAM 18.00 GB
timebase 125/3 · page size 16384 · sandbox container: none

== 1. PID enumeration ==
proc_listallpids: 716 · sysctl KERN_PROC_ALL: 716 · ps -A: 716
pid 0 present: libproc true · kinfo true · ps false

== 2. Per-process fields by owner (ok/total, errno of failures) ==
field                     own         root        other       failure errnos
bsdinfo(ppid,start,uid)   514/521     0/119       0/76        No such process(3)×7 Operation not permitted(1)×195
taskinfo(cpu,rss)         514/521     0/119       0/76        No such process(3)×7 Operation not permitted(1)×195
rusage_v4(cpu,footprint)  521/521     0/119       0/76        Operation not permitted(1)×195
pidpath                   509/521     118/119     76/76       No such file or directory(2)×1 No such process(3)×12
cwd(vnodepath)            514/521     0/119       0/76        No such process(3)×7 Operation not permitted(1)×195
argv(procargs2)           514/521     0/119       0/76        Invalid argument(22)×202
bsdinfo vs kinfo_proc start time: agree 514, differ 0
ps fallback for root processes: 119 rows · nonzero TIME 118 · nonzero RSS 119

== 3. CPU sample (5.0s, 100% = one core) ==
elapsed 5.006s (monotonic) · snapshot A took 2 ms for 710 pids
pids: 710 → 723 · vanished 8 · appeared 21 · identity changed 0 · no bsdinfo (EPERM/ESRCH) 200
CPU delta available: taskinfo 502/502 · rusage 502/502 · taskinfo vs rusage differ by >2 pts: 0
host (host_processor_info): 47.4% of 11 cores busy = 5.22 cores · per-core busy %: 68 55 46 39 31 28 54 48 54 54 45
sum of per-process CPU: 258.7% = 2.59 cores (processes that lived through the interval only)

pid        cpu%     ru%       rss  footprint  thr  owner age     name · path
12672      97.7    97.7    288 KB       1 MB    1  own   5s      yes · /usr/bin/yes            (fixture)
89843      47.3    47.3    346 MB    1.86 GB  242  own   7m 18s  CapCut · /Applications/CapCut.app/…
90425      23.3    23.3    876 MB    1.87 GB   23  own   6m 59s  VTDecoderXPCService · /System/Library/Frameworks/VideoToolbox.framework/…
1376       19.8    19.8     29 MB     430 MB   22  own   22h 4m  Claude Helper · /Applications/Claude.app/…
13897       6.3     6.3     28 MB     338 MB   22  own   2d 6h   Superset Helper · /Applications/Superset.app/…
busy fixture `yes`: probe taskinfo 97.7% · rusage 97.7% · ps -o %cpu: 98.4%

== 4. System memory ==
vm_statistics64: free 202 MB · active 2.81 GB · inactive 2.68 GB · wired 5.42 GB · compressed 6.29 GB · of 18.00 GB
vm.swapusage: used 8.55 GB of 10.00 GB, encrypted true
kern.memorystatus_vm_pressure_level: 2 = warning
kern.memorystatus_level (percent available): 32

== 5. Thermal ==
ProcessInfo.thermalState: nominal
pmset -g therm: Note: No thermal warning level has been recorded / No performance warning level / No CPU power status
parsed: values [] · throttling indicated: no limit keys reported

== 6. Grouping of own processes ==
own processes: 508 · with argv 508 · with cwd 508 · matched a rule: 49
pid     cpu%  age     ppid  kind                   project (basis)                  ancestry · argv
12874    0.2  2d 6h   1     node script: worker.js ~/.superset/projects/<project-a> (cwd)  launchd(1) · node ~/.superset/projects/<project-a>/scripts/worker.js
74218    0.1  40m     1     node (unclassified)    ~/Developer/<project-b> (cwd)   launchd(1) · npm run dev
74254    0.0  40m     74218 next dev               ~/Developer/<project-b> (cwd)   node(74218) → launchd(1) · node ~/Developer/<project-b>/node_modules/.bin/next dev
74255    0.0  40m     74254 next-server            ~/Developer/<project-b> (cwd)   node(74254) → node(74218) → launchd(1) · next-server (v16.4.3)
51071    2.1  15m     50578 claude                 ~/.superset/worktrees/<project-d> (cwd)  zsh(50578) → Superset(15848) → Superset(15122) → Superset(13891) · claude --dangerously-skip-permissions --model …
68018    0.6  55m     67268 opencode               ~/Developer/<project-c> (cwd)   zsh(67268) → Superset(15848) → … · opencode --prompt …
own processes with PPID 1: 351 · user-space candidates after dropping system/app paths: 13
orphan fixture: listed as a PPID-1 candidate · ancestry ["launchd(1)"]

== 7. Fixture cleanup ==
busy yes pid 12672: identity verified, SIGTERM sent · confirmed exited
orphan sleep pid 12676: identity verified, SIGTERM sent · confirmed exited
```

## Deployment target

`Package.swift` sets macOS 14.0, matching the app worker's assumption. Every API above exists
since macOS 10.9–10.15; `MenuBarExtra` with `.window` style needs 13; Swift Testing and Swift 6
language mode need the toolchain, not a newer target. Nothing in Phase 1 or 2 needs 15+, so 14.0
is the right floor (it keeps the user's other Macs eligible, if any). Raise only if a later
feature demands it.

## Chosen API per field (what Phase 1 implements)

| Field | Primary | Fallback / note |
|---|---|---|
| PID list | `proc_listallpids` | `sysctl KERN_PROC_ALL` (also gives ppid/uid/start/comm for everyone; fetch it once per snapshot anyway) |
| Identity | `(pid, pbi_start_tvsec·1e6 + usec)` → `ProcessIdentity` | same value from `kinfo_proc.p_starttime` for refused pids |
| PPID, uid, name | `PROC_PIDTBSDINFO` (`pbi_name`) | `kinfo_proc` (`p_comm`, 16 chars) |
| Path | `proc_pidpath` | — (works for all) |
| CPU time | `PROC_PIDTASKINFO` ticks × timebase | root/other: `ps -A -o pid=,time=` twice; mark `detailAccess = .permissionDenied` when neither |
| RSS | `PROC_PIDTASKINFO.pti_resident_size` | `ps … rss=` |
| Footprint | `proc_pid_rusage(V4).ri_phys_footprint` | none for root/other |
| argv | `KERN_PROCARGS2` + `ProcArgsParser` | nil ("Not accessible") |
| cwd | `PROC_PIDVNODEPATHINFO` | nil |
| Host CPU | `host_processor_info` deltas → `CPULoadTicks` | — |
| Memory | `host_statistics64` + `vm.swapusage` + `kern.memorystatus_vm_pressure_level` + `kern.memorystatus_level` | — |
| Thermal | `ProcessInfo.thermalState` | `pmset -g therm` notes via `PmsetThermParser`, optional |

## Phase 1 proposal

### Module boundary (all inside `HeatLensCore`; the app target only renders)

```
ScanCoordinator (actor)        one scan at a time; Task-based; cancellation; progress (elapsed/total)
  ├─ ProcessSampler (protocol) snapshot() → [pid: raw counters + identity]; two calls bracket the interval
  │    ├─ LibprocProcessSampler   proc_listallpids / proc_pidinfo / proc_pid_rusage / proc_pidpath / sysctl
  │    └─ PSTimeSampler           `ps -A -o pid=,time=,rss=` parsed; used only for pids libproc refused
  ├─ SystemSampler               host ticks, vm stats, swap, pressure, thermal, pmset → SystemSample
  ├─ ProvenanceResolver (pure)   [ProcessSample] → [ProcessGroup]   (ancestry, tool hints, project from cwd/argv)
  └─ RulesEngine (pure)          ScanSnapshot + [ProcessGroup] → [DiagnosticFinding], ranked impact-first
Redactor (pure)                  ScanSnapshot/findings → export text/JSON with ~ and argv redaction (FR-11)
```

Samplers touch the kernel and are tested with fixture child processes (`sleep`, `yes`) the test
spawns and stops by PID. Resolver, rules and redactor are pure functions over the model types and
are tested with synthetic `ScanSnapshot`s covering PRD §9 (the probe output above is the template
for those fixtures).

### Shared model types, now in `Sources/HeatLensCore/Model/`

Landed in this phase so the Phase 1 briefs can start disjoint. They are a first cut; a Phase 1
worker may add fields but should keep names and Codable shape (export format).

- `ProcessIdentity` — `(pid, startTimeMicros)`, `startDate`, `uptime(at:)`.
- `ProcessSample` — identity, parentPID, owner (`ProcessOwner`), name, executablePath?, arguments?,
  currentDirectory?, cpu (`CPUTime` delta)?, cpuPercentOfOneCore?, residentBytes?, footprintBytes?,
  threadCount?, `detailAccess: DetailAccess` (available / permissionDenied / processExited / notSupported).
- `SystemSample` — coreCount, hostBusyFraction, perCoreBusyFraction, `MemorySnapshot` (totals, swap,
  swapOutsDelta, `MemoryPressureLevel`, availablePercent), `ThermalState` (incl. `.unavailable`),
  pmset limits?.
- `ScanSnapshot` — id, startedAt, interval, system, processes, notices.
- `ProcessGroup`, `ProjectAttribution` — resolver output with evidence and confidence.
- `DiagnosticFinding`, `Severity`, `Confidence`, `Evidence`, `SuggestedAction` — PRD §4.3.
- Sampling primitives: `MachTimebase`, `CPUTime`, `CPULoadTicks`, `CPUMath` (delta with
  nil-on-backwards, percent of one core / of machine).
- Parsers: `ProcArgsParser`, `PmsetThermParser`.

### Suggested split into disjoint Phase 1 briefs

1. **Engine samplers + coordinator** (`Sources/HeatLensCore/Sampling/`, `Coordinator/`): `LibprocProcessSampler`
   (port `Sources/heatlens-probe/Libproc.swift`, which already has the wrappers), `PSTimeSampler`,
   `SystemSampler`, `ScanCoordinator` with cancellation and progress, producing `ScanSnapshot`.
   Tests: fixture children, cancellation leaves no child, PID-reuse yields `processExited`.
   May also delete `Sources/heatlens-probe/` once the coordinator reproduces its report, or keep
   it as a dev tool.
2. **ProvenanceResolver + RulesEngine + Redactor** (`Sources/HeatLensCore/Provenance/`, `Rules/`,
   `Export/`): pure code against the model types, with synthetic snapshots for every PRD §9
   scenario (the resolver lessons in §8 above are the acceptance list). Independent of brief 1.
3. **Popover UI wired to `ScanCoordinator`** (`App/`): scan/cancel/progress, overview, grouped
   processes, findings cards, data-quality notices, copy report. Can start against a stub
   coordinator that returns a fixture `ScanSnapshot`, then switch to brief 1's.
4. (Optional, small) **Process-info fallback polish**: `ps` parser hardening, "same-app XPC
   service" attribution via bundle path, project-root walk with `stat`-only checks.

Briefs 1–3 touch disjoint directories; only `Package.swift` (adding nothing beyond the existing
targets) and `Sources/HeatLensCore/Model/` (additive edits, named in handoffs) are shared.

## Not verified / open risks

- `pmset -g therm` under actual throttling: the parser handles the documented `CPU_Speed_Limit`
  lines but this machine never emitted them. Treat any limit <100 as an *info* finding until seen.
- E/P core order in `host_processor_info` is assumed, not verified; Phase 1 should not label clusters.
- `ps` fallback cost (~30 ms per run here) and its behaviour when hundreds of root processes
  churn were not profiled; FR-12 profiling is Phase 2.
- A notarised, Developer-ID-signed build was not tested; ad-hoc signing was. Hardened runtime
  should not change any of the above (no task ports are used), but Jarvis should re-run the
  probe from the signed app bundle once once signing exists.
- The orphan fixture lives up to 60 s if the probe is killed mid-run; it self-terminates.
