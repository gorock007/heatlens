# Docs: README and limitations document

status: done
agent: opencode big-pickle
brief: handoffs/briefs/2026-10-26-1753-docs-readme-limitations.md

## What the user asked

Create `README.md` (build, run, test, CLI, privacy, status, doc links), create
`docs/LIMITATIONS.md` from the feasibility and PRD material, and add one note under the first
heading of `docs/FEASIBILITY.md`. No code changes.

## What changed

- Added a README with the PRD core promise, requirements, exact commands for the app build, app
  build-only, engine tests and developer CLI, the five privacy bullets, the Phase 1 status line
  and links to the PRD, feasibility and limitations docs.
- Added a numbered limitations document covering per-user visibility, `ps` root CPU resolution,
  `kernel_task`, temperature, coarse thermal state, no GPU percentage, sandbox visibility, and
  that "possible leftover" flags are not proof.
- Inserted the requested Phase 1.1 note under the first heading of the feasibility document;
  nothing else in that file changed (`git diff --stat` reports 2 insertions).

## Files

- README.md — created
- docs/LIMITATIONS.md — created
- docs/FEASIBILITY.md — modified (one inserted note line plus blank line)

## Checks run

- `head -5 docs/FEASIBILITY.md` — note appears directly under the heading.
- `git diff --stat -- docs/FEASIBILITY.md` — `1 file changed, 2 insertions(+)`.
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30` — build complete; 63 tests in 14 suites passed.
- `scripts/run-app.sh --build-only 2>&1 | tail -20` — succeeded, printed the built `.app` path.
- README covered all required commands; not checked: launching the app and comparing a scan with Activity Monitor (user verification step).

## Processes left running

none

## Questions for the user

none

## Notes for Jarvis

Suggested commit message: `docs: add README and limitations, note Phase 1 CLI in feasibility`
