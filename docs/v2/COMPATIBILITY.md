# HeatLens v2 compatibility matrix

"Verified" means measured on that exact machine and OS, with the command recorded. Everything
else is unverified and is labelled that way in the UI. Last updated 2026-10-27 (after Phase 1).

## Machines

| Machine | macOS | Status |
|---|---|---|
| MacBook Pro 14" M3 Pro (Mac15,6), 5 P + 6 E, 14-core GPU, 18 GB, 2 fans | 27.0.1 (26A434) | **Verified:** everything in the tables below |
| Other Apple Silicon (M1–M4 families, Pro/Max/Ultra) | 14.0+ | Unverified. Expected to work for process, system and Docker data. Sensor key families vary by chip. |
| Fanless (MacBook Air) | 14.0+ | Unverified. Fans are expected to show "No fans reported". |
| Intel Macs | — | Not a target (unchanged from v1). |
| macOS 14–26 | — | Unverified. The deployment target stays 14.0. Process and system APIs are unchanged since 10.15. |

## Readings

| Reading | Source | Unit | Interval | Privilege | Public API? | M3 Pro / 27.0.1 | When missing |
|---|---|---|---|---|---|---|---|
| Thermal state | `ProcessInfo.thermalState` | nominal/fair/serious/critical | per tick / scan | none | ✅ | ✅ | "Unavailable" |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | bool | per tick | none | ✅ | ✅ read (off) | — |
| AC / battery / charge % | IOKit `IOPSCopyPowerSourcesInfo` | % / state | per tick | none | ✅ | ✅ AC 85 % not charging (matched `pmset -g batt`); later read battery 57 % | "No battery" |
| Host CPU load | `host_processor_info` | fraction of cores | delta between reads | none | ✅ | ✅ (FEASIBILITY.md) | — |
| Memory pressure, swap | sysctl `kern.memorystatus_vm_pressure_level`, `vm.swapusage`, `host_statistics64` | level / bytes | per read | none | ✅ (sysctl) | ✅ | "unknown" |
| CPU temperature avg / hottest | SMC `Tp*` `Te*` `Ts*` (`flt`) | °C | per read, ~15 ms | none | ❌ private | ✅ 77 keys, matched macmon | "Unavailable (no SMC keys)" |
| GPU temperature avg / hottest | SMC `Tg*` (`flt`) | °C | same | none | ❌ private | ✅ 18 keys | same |
| Fan RPM / max | SMC `F<n>Ac`, `F<n>Mx`, `FNum` | RPM | same | none | ❌ private | ✅ 2 fans, max 6800 | "No fans reported" |
| System power | SMC `PSTR` (`flt`) | W | same | none | ❌ private | ✅ matched macmon | "Unavailable" |
| CPU / GPU power | IOReport CLPC energy counters | W | delta | none | ❌ private, per-firmware IDs | ⛔ not implemented (ADR-0001) | "Unavailable (needs per-macOS power tables)" |
| Per-process CPU, RSS, footprint | libproc | % of one core / bytes | delta | own processes only | ✅ | ✅ | "Not accessible" + reason |
| Root-process CPU | `/bin/ps` (scan only) | % of one core | delta | none | ✅ | ✅ | Live: "Live mode doesn't sample CPU for N root/other-user processes" |
| Containers, image, state, labels | Docker Engine API `GET /containers/json` | — | per read, ~2 ms | user owns socket | ✅ (Docker) | ✅ Docker Desktop 28.5.1, API 1.51 | `DockerAvailability` state |
| Container CPU / memory | `GET /containers/{id}/stats?one-shot=true` | % of one core / bytes | delta, ~12 ms each | same | ✅ | ✅ | "No stats" |

## Docker runtimes

| Runtime | Socket | Status |
|---|---|---|
| Docker Desktop 28.5.1 | `~/.docker/run/docker.sock` (`/var/run/docker.sock` → symlink) | Verified (API 1.51) |
| Colima, OrbStack, Podman, Rancher Desktop | various | Unverified. Not probed in Phase 1. |

## Known private-interface risks

- SMC key names and types differ between chip generations. The provider discovers keys at
  runtime and never assumes a key exists.
- The `SMCKeyData` struct must be exactly 80 bytes. A unit test enforces this.
- An OS update can make the SMC user client refuse calls. The provider then reports
  "Unavailable" and HeatLens keeps working.
