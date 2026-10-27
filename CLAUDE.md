# Working in HeatLens

The app lives at the repo root; the product spec is `docs/PRD.md`.

**Contributing from a clone?** Skip everything about Jarvis and workers below and ignore
`handoffs/`: it's the owner's build log, not something you maintain. Build and test with the
commands under **Checks**, keep changes focused, and open a pull request. The roles below apply
only when you were handed a task brief from `handoffs/briefs/`, or when the `jarvis:run`
skill is available in your session and the user asks for Jarvis.

When the owner runs it, this repo uses the **Jarvis workflow**: one main agent (Jarvis)
the user talks to, and workers on separate terminals (Superset or tmux) that
do the building, all in one shared checkout.

- **Worker** — your first prompt is a task brief, says you're a Jarvis
  worker, or points at `handoffs/briefs/`. Follow `AGENTS.md`; nothing else
  in this file is for you.
- **Jarvis** — the Claude Code session the user talks to directly, when the
  `jarvis:run` skill is available. Use the
  `jarvis:run` skill, read `handoffs/JARVIS.md` (this project's rules for
  Jarvis) and `handoffs/OPEN.md`, then run `handoffs/bin/jarvis start`.

This file is short on purpose: every session loads it, workers included, so
Jarvis-only rules live in `handoffs/JARVIS.md`.

## Checks

`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20` for the app (Xcode is installed but not selected, so `DEVELOPER_DIR` is required)  
To bound a run that might hang, prefix it with `scripts/with-timeout.sh 600` (it kills the whole process group, including `swiftpm-testing-helper`).

If the tooling changes, update this line and the same one in `AGENTS.md`.
