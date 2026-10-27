# ADR-0002: Docker through a read-only Engine API client on the local Unix socket

- **Status:** Accepted for Phase 1 (2026-10-27)
- **Context:** PRD-v2 §4 (Docker Engine API), §6 Phase 1 "Docker", §8 (Docker socket is privileged)

## Decision

1. Add `DockerEngineClient` to `HeatLensCore`: a minimal HTTP/1.1 client over an `AF_UNIX`
   socket. It is written on POSIX sockets, because `URLSession` cannot connect to a Unix socket.
   It sends `GET` only. There is no other verb in the code.
2. **Allowlist of paths.** The only requests are `/_ping`, `/version`,
   `/v1.<n>/containers/json?all=1` and
   `/v1.<n>/containers/<id>/stats?stream=false&one-shot=true`. `<id>` must match
   `^[0-9a-f]{12,64}$` and come from the Engine's own container list. No string from a process
   name, a label or the user is ever put into a path.
3. **Socket discovery is local files only.** In order: `$HOME/.docker/run/docker.sock` (Docker
   Desktop), then `/var/run/docker.sock`. The path must exist, be a socket, and be owned by the
   current user or root. A `DOCKER_HOST` that is not `unix://` is ignored. TCP is never used.
   Colima and OrbStack paths can be added once they're tested.
4. **Opt-in.** A Settings switch, "Docker containers", off by default. When it is off, HeatLens
   never opens the socket.
5. **Never starts Docker.** HeatLens doesn't launch Docker Desktop and doesn't run `docker`, `open`
   or `launchctl`. A missing socket is reported as such.
6. **Explicit states** in `DockerAvailability`: `disabled`, `socketNotFound`,
   `permissionDenied`, `daemonNotResponding`, `unsupportedAPI(version)`, `error(message)`,
   `available(version)`. Each state has a one-line UI explanation.
7. **CPU convention matches processes:** 100 % = one core. Two one-shot `total_usage` readings
   (ns) bracket the sampling interval. `cpuPercent = Δtotal_usage / Δwall × 100`. Memory is
   `usage − inactive_file`, which is what `docker stats` shows. The VM's `online_cpus` is kept as
   context ("of 6 VM CPUs").
8. **Bounded cost:** at most 20 running containers get stats per sample, with a 2 s deadline per
   request. Requests run serially. If more containers are running, the list says "stats for 20 of N".
9. **Labels are data.** Compose labels (`project`, `service`, `working_dir`, `config_files`) are
   kept as evidence for Phase 2 attribution. In exports, `working_dir` and `config_files` go
   through the `Redactor` path rules.

## Why not

- **The `docker` CLI as a subprocess:** it's slower (hundreds of ms per call) and its output
  formats drift. It can also be a user-installed wrapper. PRD-v2 §8 prefers structured APIs to
  shell calls.
- **`stats?stream=false` without `one-shot`:** the Engine waits about 1–2 s per container to
  build its own interval. One-shot plus HeatLens's interval is faster and keeps one time base.
- **A Swift Docker SDK:** it would be a dependency for four GET requests, and most such packages
  include write APIs we would have to audit.

## Security review notes

- The Docker socket is effectively root on the VM, and through bind mounts on the user's
  files. Mitigations: GET only, a fixed path allowlist, IDs validated against a hex pattern,
  response size capped (4 MB per response), no redirects followed, nothing reached from the
  network, no plugin or MCP access to the client. The CLI and MCP server do not get Docker
  data in Phase 1.
- Response parsing uses `JSONDecoder` into fixed `Decodable` types. Unknown fields are ignored.
  Chunked transfer encoding is supported, with a cap on chunk sizes.

## Evidence

See [GAP-ANALYSIS.md §6](GAP-ANALYSIS.md#6-docker-spike-summary): Docker Desktop 28.5.1,
API 1.51, list in 2 ms, one-shot stats in 12 ms. `fda-db-1` (`postgres:17`, Compose project
`fda`) was running at the time.

## Revisit when

- Phase 3 needs to stop a selected container. That would be the first non-GET request. It
  needs its own ADR, a confirmation flow and a security review.
- The owner uses Colima, OrbStack or Podman. Add socket paths after testing.
