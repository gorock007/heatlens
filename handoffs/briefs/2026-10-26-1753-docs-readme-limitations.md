# Docs: README with build/run instructions and a limitations document
worker: opencode
model: <use the model selected in OpenCode>
effort: low
started: 2026-10-26 17:53 · terminal: 34ff88a1-f661-4af2-a0ce-4bc5777beb22

## Goal
Create `README.md` and `docs/LIMITATIONS.md`, and add one note at the top of `docs/FEASIBILITY.md`. Writing only; no code changes. Done means these three files read correctly and every command in the README is copied exactly from this brief.

## Context
- Source material, to read but not edit except as stated: `docs/PRD.md` (sections 1, 2, 5, 10, 11), `docs/FEASIBILITY.md` (the "Summary of decisions" and "Not verified / open risks" sections).
- **Pattern to copy:** the plain, short style of `docs/FEASIBILITY.md` "Summary of decisions": numbered points, one fact each, no marketing language.

## What to write
1. **`README.md`** (under ~80 lines):
   - One-paragraph description: copy the PRD's "Core promise" line, plus a sentence on on-demand, read-only and offline.
   - **Requirements:** macOS 14+, Apple Silicon, Xcode installed at `/Applications/Xcode.app`, `xcodegen` (`brew install xcodegen`).
   - **Build and run the app:** `scripts/run-app.sh` (build and launch), or `scripts/run-app.sh --build-only`.
   - **Engine tests:** `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test`
   - **Developer CLI:** `swift run heatlens-probe` (same `DEVELOPER_DIR` export).
   - **Privacy:** five bullets from PRD section 5. These are no network, no telemetry, no file contents read, nothing stored except settings, and reports redact home paths and arguments.
   - **Status:** "Phase 1 (read-only MVP) in progress; process termination is not implemented."
   - Links to `docs/PRD.md`, `docs/FEASIBILITY.md` and `docs/LIMITATIONS.md`.
2. **`docs/LIMITATIONS.md`**: numbered, plain statements a user should know. Take them from FEASIBILITY "Summary of decisions" points 2, 3, 4 and 7 and "Not verified / open risks", and from PRD section 2 non-goals:
   - only the current user's processes give full details
   - root processes get CPU from `ps` at 10 ms resolution
   - `kernel_task` has no numbers
   - there's no temperature reading
   - the thermal state is the OS's coarse state
   - there's no GPU percentage
   - a sandboxed build would see much less
   - flags such as "possible leftover" are not proof
3. **`docs/FEASIBILITY.md`**: insert only this line directly under its first heading, and change nothing else: `> Note: the probe has since become a thin CLI over \`ScanCoordinator\` (Phase 1.1); the sample output below is from the Phase 0 spike and its format differs from today's \`heatlens-probe\`.`

## Scope
- May touch: `README.md` (create), `docs/LIMITATIONS.md` (create), `docs/FEASIBILITY.md` (that one inserted line only)
- Must not touch: everything else, especially `Sources/`, `App/`, `Tests/`, `docs/PRD.md`, `handoffs/` (except your handoff file). Never run git commands that change state.

## Checks
`head -5 docs/FEASIBILITY.md` shows the note. `git diff --stat -- docs/FEASIBILITY.md` shows exactly 2 insertions (the line and a blank line). Commands in README match this brief character for character.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. Otherwise, write the files and hand off per `AGENTS.md`.
