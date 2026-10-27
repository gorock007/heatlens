# ADR-0004: Projects come from stat-only repository roots, Compose labels and bind mounts

- **Status:** Accepted for Phase 2 (2026-10-27)
- **Context:** PRD-v2 §6 Phase 2 ("infer project by cwd, executable path, repo root, Docker
  Compose labels, container bind mounts and optional user-defined mappings"; "avoid
  double-counting host Docker VM CPU and per-container CPU")

## Decision

1. **Process groups keep their v1 directory** (cwd, else an argv path). `ProjectAttributor` maps
   that directory to a `Project`, in this order:
   1. a **user mapping** from Settings ("Project folders": `~/Developer/FDA = FDA`), longest
      prefix on whole path components;
   2. the **repository root** found by `ProjectRootLocator`: the nearest ancestor with `.git`
      (a directory, or a worktree's `.git` file), else the nearest with a manifest
      (`package.json`, `Package.swift`, `Cargo.toml`, `pyproject.toml`, `go.mod`, …);
   3. the directory itself, one confidence step lower ("working directory").
2. **The locator only checks existence** (`fstatat` with `AT_SYMLINK_NOFOLLOW`). It never opens
   or reads a file, and never runs `git`.
3. **Containers** are attributed from evidence already in `GET /containers/json`: a user
   mapping over any container path; the Compose `working_dir` label; the folder of the Compose
   `config_files` label; then bind mounts, but only when they all fall into one project.
   Anything else is **Unattributed**, with the reason. A Compose project *name* alone is never
   matched to a folder.
4. **No new Docker endpoint.** The container list already carries `Mounts`; the planned
   `GET /containers/{id}/json` isn't needed. `DockerContainerSummary` decodes only
   `Mounts[].Type` and `Mounts[].Source`, and keeps bind sources.
5. **Per-project totals** (`ProjectAttributor.breakdown`): every live process goes to its
   group's project, or Unattributed. Docker's VM process (`com.apple.Virtualization.VirtualMachine`)
   goes to its own "Docker VM" row when Docker answered. Container CPU is **moved** from that row
   to the container's project. The rows then add up to the host's measured CPU. Container
   memory is shown beside a project's memory, never added, because the VM's footprint already
   holds it. Energy is host-process energy only.

## Options considered

| Option | Against |
|---|---|
| Run `git rev-parse --show-toplevel` | A subprocess per directory, `git` may not be installed, and it reads repository files. |
| Read `package.json` `name` for the project name | Reads file contents, which v1 promised never to do. The folder name is enough. |
| `GET /containers/{id}/json` for mounts | A new endpoint and a security review for data the list already has. The inspect payload also holds `Config.Env`, which often carries secrets. |
| Add container CPU to project totals and leave the VM row as is | Counts the same CPU twice (PRD-v2 Phase 2 forbids it). |
| Match Compose project names to folder names | A guess. The PRD asks for "unknown/unattributed workloads instead of guessing". |

## Security and privacy review

- **No file content is read.** The locator issues `fstatat` on `<ancestor>/<marker>` paths only.
- **Privacy-protected folders are never touched.** A stat inside `~/Desktop`, `~/Documents`,
  `~/Downloads`, `~/Library` (iCloud Drive lives there), other volumes (`/Volumes`) or
  network mounts (`/Network`) can make macOS ask the user to grant HeatLens access, or block
  on an unreachable share. The locator skips them; processes there keep their cwd as the
  project ("working directory"). Tested with a fake filesystem that records every check.
- **Bounded:** at most 16 levels and never at or above the home directory (a dotfiles `~/.git`
  would claim everything). Results, including misses, are cached for 5 minutes in at most
  2,048 entries, so live mode does a few stats per *new* directory, not per tick.
- **Inputs:** directories come from the user's own processes (cwd/argv) and container labels.
  Paths are only concatenated with fixed marker names and passed to `fstatat`. No shell, no
  `open`, nothing executed. Bind sources that are sockets, system or temp paths, or dot folders
  in home (`~/.ssh`, `~/.docker`) are ignored.
- **Docker:** still GET-only to the same allowlisted paths (ADR-0002). Nothing new is sent.
- **User mappings** are data. They only rename and regroup; they can't widen what is read.
- **Exports** are unchanged in this brief: projects aren't in the copied reports yet.

## Evidence (this M3 Pro, 2026-10-27)

`heatlens-probe --live 20 --interval 5`, Docker Desktop with `fda-db-1` running: every tick listed
`FDA … (1 containers)` first, from the `working_dir` label and the repository's `.git`, and
named other running projects by their repository folders. The container list returned `Mounts`
(here a named volume, which is correctly ignored). The live test checks that each running
Compose container gets a project whose root exists and contains its `working_dir`.

## Consequences

- A CPU spike in Live or a scan leads to a named repository and its process groups and
  containers (Phase 2 exit, together with the timeline in 2d).
- Another app running a Virtualization VM at the same time (UTM, Lima's `vz`) is
  indistinguishable from Docker's: both land in the Docker VM row, with a notice.
- Runtimes other than Docker Desktop (Colima with QEMU, OrbStack) may not show that VM process;
  then container CPU is listed per project but kept out of totals, with a notice.
