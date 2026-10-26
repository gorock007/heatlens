# Phase 2e: FR-12 performance numbers, PRD §9 coverage matrix, synthetic sample reports
worker: claude
model: sonnet
effort: medium
started: 2026-10-26 19:46 · terminal: 7f1e047a-3297-4919-8516-9b1fb90da03a

## Goal
Write down three of PRD §10's deliverables with evidence: measured footprint and scan cost (FR-12), a scenario-by-scenario coverage matrix for PRD §9, and sample reports. Done means `docs/PERFORMANCE.md`, `docs/SCENARIOS.md` and `docs/samples/` exist, every number has the command that produced it, and the samples come **only** from synthetic fixtures.

## Context
- Spec: PRD §5 (performance), §9 (12 scenarios), §10, §11, FR-12. The previous handoffs in `handoffs/merged/` already recorded idle numbers. Start from those, and from `docs/FEASIBILITY.md` for style.
- **Pattern to copy:** `docs/LIMITATIONS.md` (plain numbered facts). For samples, follow `Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift` plus `Redactor.textReport` / `jsonReport`.

## What to do
1. **`docs/PERFORMANCE.md`:**
   - **App idle:** launch with `scripts/run-app.sh`, take its PID, then after 30 s and again at 60 s record `ps -o %cpu=,rss=,time=` and `top -l 1 -pid <pid> -stats pid,cpu,mem,idlew`. Quit it.
   - **Scan cost:** run `swift run -c release heatlens-probe --report --no-fixtures` under `/usr/bin/time -l` three times, recording wall time, user+sys CPU and max RSS. Note that a 10 s scan's wall time is mostly the sample interval.
   - **Snapshot cost:** if a test or the probe prints it, include it.
   - Say plainly what isn't measured: idle after a real scan in the app, which needs a click.
   - Before and after, check that no `heatlens-probe`, `ps` or HeatLens process you started is left.
2. **`docs/SCENARIOS.md`:** a table of the 12 PRD §9 scenarios. Columns: scenario · how it's covered (test name with `file:line`, or "manual: <exact clicks>") · status (covered / partial / manual only). Read the tests to fill it. Don't invent coverage. If a scenario has no test, say so.
3. **`docs/samples/`:**
   - Add a tiny test, `Tests/HeatLensCoreTests/SampleReportTests.swift`. It renders the PRD §7 synthetic scenario (`SyntheticSnapshots`), runs it through `ProvenanceResolver` and `RulesEngine`, and writes `report.txt` and `report.json` **only when** the env var `HEATLENS_WRITE_SAMPLES=<dir>` is set. Otherwise it only asserts that both render.
   - Generate the files with `HEATLENS_WRITE_SAMPLES=$PWD/docs/samples swift test --filter SampleReport`. Pass `homeDirectory: "/Users/example"` so the redaction shows.
   - Check the output contains only invented names.
4. **`README.md`:** add links to the three new docs. Change the Status line to "Read-only diagnosis and confirmed safe stop (SIGTERM only) implemented; not yet signed/notarized."

## Scope
- May touch: `docs/PERFORMANCE.md`, `docs/SCENARIOS.md`, `docs/samples/` (create), `Tests/HeatLensCoreTests/SampleReportTests.swift` (create), `README.md` (links and the Status line only)
- Must not touch: `Sources/`, `App/`, other tests, `docs/PRD.md`, `docs/FEASIBILITY.md`, `docs/LIMITATIONS.md`
- **Never paste real scan output.** Performance numbers are fine. Process names, paths and argv from this Mac are not.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`. `grep -rniE "$(whoami)|/Users/[a-z]" docs/samples docs/PERFORMANCE.md docs/SCENARIOS.md` must print only `/Users/example` lines. Run `handoffs/bin/jarvis leftovers --mine`.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
