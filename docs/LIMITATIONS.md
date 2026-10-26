# HeatLens limitations

1. Only the current user's processes give full details. For root and other-user processes,
   command line, working directory, memory footprint and libproc CPU are not available.
2. Root-process CPU comes from `ps` at 10 ms resolution, so small differences between samples
   may not be visible.
3. `kernel_task` has no numbers. It reports no CPU or memory figures to HeatLens, only its name
   and owning user.
4. There is no temperature reading. No supported API provides a reliable per-chip temperature.
5. The thermal state is the OS's coarse state (nominal, fair, serious, critical), not a
   measurement of how hot the Mac is.
6. There is no GPU percentage. WindowServer CPU is shown as UI/rendering activity instead.
7. A sandboxed build would see much less: no `ps` fallback for system processes, no physical
   footprint, and no `proc_listallpids`. HeatLens ships unsandboxed for this reason.
8. Flags such as "possible leftover" are not proof. They are review candidates based on
   evidence, and a process may be intentional or doing useful work.
