# HeatLens limitations

1. Only the current user's processes give full details. For root and other-user processes,
   command line, working directory, memory footprint and libproc CPU are not available.
2. Root-process CPU comes from `ps` at 10 ms resolution, so small differences between samples
   may not be visible.
3. `kernel_task` has no numbers. It reports no CPU or memory figures to HeatLens, only its name
   and owning user.
4. Temperatures, fans and system power come from the SMC, an undocumented interface. "Hardware
   sensors" is on by default and can be turned off in Settings. The readings may stop working after a
   macOS update; HeatLens then shows "Unavailable". The values are averages and maxima of SMC
   sensor families whose meanings are community-documented, not Apple's. "Hottest" is the
   hottest sensor read, not a measured die hotspot. Verified on one M3 Pro only
   (docs/v2/COMPATIBILITY.md).
5. The thermal state is the OS's coarse state (nominal, fair, serious, critical), not a
   measurement of how hot the Mac is.
6. There is no GPU percentage. WindowServer CPU is shown as UI/rendering activity instead.
7. A sandboxed build would see much less: no `ps` fallback for system processes, no physical
   footprint, and no `proc_listallpids`. HeatLens ships unsandboxed for this reason.
8. Flags such as "possible leftover" are not proof. They are review candidates based on
   evidence, and a process may be intentional or doing useful work.
9. Whole-chip CPU and GPU power are always "Unavailable". On macOS 27 they need per-firmware
   energy-counter tables (docs/v2/ADR-0001). System power (SMC `PSTR`) is shown instead, and
   "CPU energy" per process (item 16).
10. Live mode doesn't sample CPU for root and other-user processes, because it never runs `ps`.
    Scan now still includes them.
11. Live mode keeps at most 150 updates of trend history in memory and forgets them when it
    stops. With "Keep watching in the background" off (the default), it pauses itself after 15
    minutes and stops when the panel closes. With it on, sampling goes on after the panel closes,
    every 30 s on power, 60 s on battery and 5 or 10 s while something is busy (120 s in Low Power
    Mode), until you press Pause or quit HeatLens. Quitting stops it. Nothing samples while
    HeatLens isn't running.
12. Docker data needs "Docker containers" on in Settings, and by default only reads Docker
    Desktop's local socket (or a `unix://` `DOCKER_HOST`). Colima, OrbStack and Podman are
    untested. At most 20 running containers get CPU and memory per reading. With "Allow stopping
    a container" on, HeatLens can stop one selected container from a scan result, only through
    Docker Desktop's own socket; a `DOCKER_HOST` socket stays read-only.
13. Container CPU is part of the Docker VM process's CPU, not extra load. Don't add the two.
    Containers are not yet attributed to projects; Compose labels are shown as evidence only.
14. Safari and other WebKit content processes run as Apple XPC services and are grouped with
    macOS user services, not with the browser. Chromium-based browsers and Firefox group correctly.
15. Custom labels match a process name, executable or argument token exactly (case-insensitive).
    They never apply to root, other-user or protected system processes.
16. "CPU energy" comes from macOS's per-process energy counter (`proc_pid_rusage`, a public API).
    It covers your own processes only: root and system processes, `kernel_task` and the CPU's
    shared power aren't readable, so the total in Live mode sits below the CPU's real power
    (about 2 W below macmon's CPU power under load on the M3 Pro, about a third of it at idle).
    It is CPU energy only, not GPU. A process that ran under 1 ms of CPU and reports no energy shows
    "Unavailable", not 0 W.
17. Projects come from the nearest Git repository (or manifest) above a process's folder, found
    by checking which files exist, never by reading them. Folders macOS guards with a privacy
    prompt (Desktop, Documents, Downloads, iCloud Drive, other volumes) are never searched, so
    work there is grouped by its folder, not its repository. Add a line under Settings →
    Project folders to name it.
18. Containers are tied to projects only by Compose's working-directory or config-file labels,
    or by bind mounts into a single project. Others are listed under the Docker VM row as
    unattributed. Container CPU comes from Docker's stats, read at slightly different moments
    from the host's, so the Docker VM row is an estimate and never shown below 0.
19. HeatLens recognises Docker Desktop's VM by its process name. Any other app's
    Virtualization VM running at the same time is counted in the same row (a notice says so).
20. Expensive commands (installs, builds, test runs) are recognised by name and arguments, and
    only when an update sees them running: a command shorter than the Live interval can be missed.
    "Several at once" and "likely repeated runs" are HeatLens's inferences, and say so.
21. The timeline covers this Live session in memory. Looking further back needs "Keep history",
    and covers only the times Live was running.
