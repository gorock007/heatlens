# Add a process-group timeout wrapper for test runs (review finding #5)
worker: opencode
model: <use the model selected in OpenCode>
effort: low
started: 2026-10-26 19:59 · terminal: 62528971-db8f-471c-b82e-993dfc13ad11

## Goal
Add `scripts/with-timeout.sh` so a hung `swift test` can be bounded without orphaning
`swiftpm-testing-helper`. Usage: `scripts/with-timeout.sh <seconds> <command> [args...]`.
It runs the command as the leader of a NEW process group. If the command exits first,
the script exits with the command's status. On timeout it sends SIGTERM to the whole group
(negative pgid), waits 5 s, sends SIGKILL to the group if anything is left, prints
`with-timeout: timed out after <N>s` to stderr and exits 124. macOS has no `timeout`/`gtimeout`,
so implement it with `/usr/bin/perl` (a `#!/bin/sh` script that execs a perl one-program using
`setpgrp(0,0)` in the forked child, `alarm`/`waitpid` in the parent, `kill('TERM', -$pid)`).
Keep it short: about 20 lines.

## Context
Review finding #5 in `handoffs/merged/2026-10-26-1935-p2c-security-review-safe-stop.md` (lines 96-100):
`perl -e 'alarm 120; exec @ARGV' swift test …` kills only `swift-test` and leaves
`swiftpm-testing-helper` orphaned. Follow the style of the existing `scripts/run-app.sh`
(shebang, `set -eu`, a short usage comment at the top).

## Scope
- May touch: `scripts/with-timeout.sh` (new, chmod +x), `AGENTS.md`, `CLAUDE.md`
- Must not touch: everything else, especially `Sources/`, `Tests/`, `App/`
- In `AGENTS.md` and `CLAUDE.md`: add ONE sentence directly under the `## Checks` command line:
  "To bound a run that might hang, prefix it with `scripts/with-timeout.sh 600` (it kills the whole process group, including `swiftpm-testing-helper`)." Change nothing else in those files.

## Phase
Single phase.

## Checks
Run all four and paste the output in the handoff:
1. `scripts/with-timeout.sh 5 true; echo "exit=$?"` → `exit=0`
2. `scripts/with-timeout.sh 5 sh -c 'exit 3'; echo "exit=$?"` → `exit=3`
3. `scripts/with-timeout.sh 2 sh -c 'sleep 60 & sleep 60'; echo "exit=$?"` → timed-out message, `exit=124`
4. Immediately after check 3: `pgrep -f 'sleep 60' || echo none-left` → `none-left` (proves the background grandchild was killed too)
Do not run `swift test` for this task.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
