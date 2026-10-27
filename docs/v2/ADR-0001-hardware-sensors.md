# ADR-0001: Hardware sensors come from a native Swift SMC reader behind a provider interface

- **Status:** Accepted for Phase 1 (2026-10-27)
- **Context:** PRD-v2 §4 decision gate, §6 Phase 0 and Phase 1 "Hardware"

## Decision

1. Add a `HardwareSensorProviding` protocol to `HeatLensCore`. Every reading is optional and
   carries its availability and source. Nothing above the provider knows how a reading was made.
2. The Phase 1 provider is **`SMCSensorProvider`**, a native Swift reader for the `AppleSMC`
   IOKit user client. It runs in-process, read-only, without root, a helper or a subprocess. It
   reports:
   - average and hottest **CPU** temperature (keys `Tp*`, `Te*`, `Ts*`, `flt`, 10–150 °C),
   - average and hottest **GPU** temperature (keys `Tg*`, same filter),
   - **fans**: `F<n>Ac` actual RPM and `F<n>Mx` maximum,
   - **system power** in watts: `PSTR`.
3. **CPU and GPU power are reported as unavailable** in Phase 1, with the reason "needs
   per-macOS power tables". Displaying an unverified number would break PRD-v2 §8.
4. **Public context stays separate and always on:** `ProcessInfo.thermalState`, Low Power Mode,
   and IOPowerSources (AC or battery, charge %, charging). The UI marks the private readings as
   such ("SMC · private interface"), so they cannot be mistaken for the OS's thermal state.
5. The SMC provider is **off by default**, under the Settings switch "Hardware sensors (private
   macOS interfaces)". When it is off, or the SMC cannot be opened, or a key is missing, the
   reading is `unavailable(reason)`. It is never zero.
6. **macmon is not bundled in Phase 1.** It stays the reference implementation and the
   cross-check tool. Bundling it, for CPU/GPU power only, is a separate decision for the owner.
   See "Revisit when".

## Options considered

| Option | For | Against |
|---|---|---|
| **A. Native Swift SMC reader (chosen)** | Same language and build as the rest of HeatLens. No new toolchain, binary or subprocess. ~15 ms in-process per read. Matched macmon exactly in the spike. | Owns about 150 lines of private-interface code. SMC key meanings are community-documented. No CPU/GPU power. |
| B. Bundle `macmon` (Rust, MIT) as `Contents/Helpers/macmon`, spawn `macmon pipe` | Gets CPU/GPU/ANE power. Upstream tracks macOS changes. | Rust toolchain in `release.sh`. A third-party binary inside the notarized bundle. A subprocess per sample (~37 ms CPU each, with start-up) or a long-lived child to supervise. Upstream changes arrive only with a HeatLens release anyway. Its `serve` mode opens an HTTP port and would have to be excluded. |
| C. Link macmon's Rust library through a C ABI shim | In-process, gets power. | Needs a wrapper crate, a static library and cross-language builds. The most build complexity for the least gain. |
| D. Port macmon's IOReport CLPC power reader to Swift | In-process, gets power. | The CLPC channel IDs change per macOS release and come from kernelcache analysis (`docs/clpc-discovery.md` upstream). HeatLens can't maintain that. Copying a snapshot of the table would silently break on the next macOS. |
| E. `powermetrics` | Apple's own tool. | Requires root. Ruled out by PRD-v2 §8. |

## Evidence (this M3 Pro, macOS 27.0.1, 2026-10-27)

**macmon 0.10.0**: cloned at tag `v0.10.0` (commit `5df67a5`, 2026-10-15) and built in a scratch
directory with `cargo build --release --locked`. Nothing was installed, and Homebrew was not
used. License MIT. Upstream is active (last push 2026-10-23) and not archived.

```
macmon pipe -s 3 -i 1000      # /usr/bin/time -l: 3.17 s real, 0.04 s user, 0.07 s sys, 18.6 MB max RSS
cpu_temp_avg 69.8 / 69.2 / 68.2 °C   gpu_temp_avg 63.5 / 63.7 / 63.4 °C
fans fan0 2314 / 2289 / 2333, fan1 2516 / 2511 / 2511 RPM (max_rpm 6800)
cpu_power 4.21 / 3.36 / 3.76 W   gpu_power 2.59 / 2.92 / 2.39 W   sys_power 18.4 / 21.2 / 21.6 W
```

`macmon debug` shows where those come from:

- **Temperatures:** SMC keys. `Tp*`/`Te*`/`Ts*` for the CPU (77 keys here), `Tg*` for the GPU
  (18 keys), averaged after a plausibility filter. IOHID `PMU tdie*` sensors are a fallback.
- **Fans:** SMC `F0Ac`/`F1Ac`, `F0Mx`/`F1Mx`. `FNum` = 2.
- **System power:** SMC `PSTR` (18.62 W at that moment).
- **CPU/GPU power:** `CLPC :: Energy Counters` (5.59 W / 2.29 W). In the same output,
  `Energy Model :: CPU Energy` reads **0.00 W**. The older channel group is dead on macOS 27.

**Native Swift spike** (scratch file, about 120 lines: `IOServiceOpen` on `AppleSMCKeysEndpoint`,
`IOConnectCallStructMethod` selector 2, an 80-byte `SMCKeyData` struct). Run side by side with
`macmon pipe -i 1000`:

```
SMC keys 2422 · cpu temp keys 77 · gpu 18 · fans ["F0Ac", "F1Ac"] · discovery 10.5 ms
spike   cpu 66.5 gpu 59.3 · F0Ac=2290/6800 F1Ac=2489/6800 · PSTR 25.59 W · read 17 ms
macmon  cpu 66.5 gpu 59.3 · [2316, 2502]                  · sys 25.59 W
spike   cpu 62.7 gpu 58.9 · F0Ac=2327/6800 F1Ac=2515/6800 · PSTR 26.94 W · read 15 ms
macmon  cpu 62.7 gpu 58.9 · [2319, 2511]                  · sys 26.94 W
spike   cpu 64.5 gpu 58.8 · …                             · PSTR 18.76 W · read 18 ms
macmon  cpu 64.5 gpu 58.8 · …                             · sys 18.76 W
```

Temperatures and system power agree exactly when the two read in the same second. Fan RPM
differs by under 1.5 %, because the two read the fans a few milliseconds apart.

The first spike run returned no keys. Swift placed the field after the 9-byte `KeyInfo` at
offset 37 instead of the C layout's 40. Explicit padding fixed it. Phase 1 must keep a
`MemoryLayout<SMCKeyData>.size == 80` test, because this failure is silent: every call fails
and every reading becomes "unavailable".

**IOReport from Swift** (`dlopen("/usr/lib/libIOReport.dylib")`): `IOReportCopyAllChannels`
lists `Energy Model` (196 channels) but no `CLPC` group. `IOReportCopyChannelsInGroup("CLPC")`
returns nothing. This confirms that CPU/GPU power on macOS 27 needs the constructed,
per-firmware channel IDs.

**Trusted cross-check:** not done for power. `sudo powermetrics` needs root, and HeatLens will
not ask for it. The owner can run
`! sudo powermetrics -n 3 -i 1000 --samplers cpu_power,gpu_power,thermal` next to the probe to
compare. The temperatures can't be checked against an Apple tool, because macOS ships none. The
UI therefore says "SMC sensor reading" and never "CPU temperature is".

## Consequences

- HeatLens can show temperatures, fans and system power on this Mac, with no new dependency.
- CPU/GPU power stays "Unavailable" until the owner chooses option B or a public API appears.
- SMC key families are verified on one machine only (M3 Pro). COMPATIBILITY.md lists other
  chips as *unverified*. The provider reports what it finds and does not assume.
- Private interfaces may break in a macOS update. The provider treats every failure as
  "unavailable" and never retries in a loop. A test pins the struct layout. Live tests skip
  rather than fail on a machine without an SMC (a VM, CI).

## Security review notes

- Read-only. The provider only issues SMC *read* commands (`data8` 5, 8 and 9: read bytes, key by
  index, key info). It never issues a write command (6). It never touches fan control (PRD-v2 §10
  defers fan control).
- No privilege, entitlement, helper or subprocess. Works in the existing unsandboxed, hardened
  runtime app.
- Inputs are fixed four-character key names from a compiled-in list, or names enumerated from
  the SMC itself. Nothing from users, processes or the network reaches the call.

## Revisit when

- The owner wants CPU/GPU power. The next step is option B: a pinned macmon release built from
  source in `release.sh`, invoked only with `pipe`, MIT notice in the About box, its own brief and
  security review.
- A macOS update changes SMC behaviour. The struct-layout and live tests catch it.
- Apple ships a public thermal or energy API.
