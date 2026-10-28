# v2 Phase 4h: Incident and the redacted incident reports (core)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1900-v2-p4h-incident-core.md

## What the user asked
Build PHASE-4-PLAN brief 4h:
- `Incident` and `IncidentBuilder` (from an explanation, an alert or the busiest moment, with a
  ±2 min window);
- `IncidentExportOptions(anonymizeProjects:)`;
- `Redactor.incidentMarkdown` and `Redactor.incidentJSON`, applying owner decision 5's keep and
  drop rules;
- `IncidentReportTests` on an FDA-shaped synthetic fixture.

There's no UI; that's 4i. I had no questions, so this is the only handoff.

## What changed
- **`Incident`** holds:
  - the trigger (`.explanation`, `.alert` or `.busiestMoment(Peak)`) and its start and end;
  - the window: start − 2 min to end + 2 min, or to now while a burst still runs, and never past
    now;
  - the explanations that overlap the window (the trigger's first) and the alerts fired inside
    it (the trigger's alert always included);
  - the action records inside the window;
  - per-minute timeline rows: average and peak CPU, the worst thermal state, peak swap, the top 3
    projects by average CPU, and that minute's events;
  - power and thermal context: worst thermal state and memory pressure, CPU average and peak,
    peak temperature and swap, and average and peak system watts.

  It's built only from what's passed in, so nothing is sampled or stored. It's `Equatable`, not
  `Hashable`, because `ActionRecord` is only `Equatable`.
- **`IncidentBuilder.incident(from:timeline:alerts:explanations:actions:margin:now:)`**:
  - There's one overload per trigger type.
  - `margin` defaults to 120.
  - `now` is a parameter so tests are deterministic.
  - A long window gets coarser rows rather than more of them: bucket = 60 s ×
    ⌈minutes / 120⌉, so there are never more than `IncidentBuilder.timelineRowLimit` (120) rows.
    The window's last instant joins the last bucket instead of opening a new one.
- **Redaction** (`IncidentScrubber`):
  - Each string goes through the scan report's `Sanitizer`: home becomes `~`, the username becomes
    `<user>`, secrets and the `--token=…` style become `<secret redacted>`, and long hex becomes
    `<redacted>`.
  - Then the drop rules run (as updated by the review fixes below):
    - PIDs in every spelling are removed from inside text;
    - standalone 12- and 64-hex tokens become `[id]`;
    - every rooted, `~`, `./` or Windows path (spaced pieces included), a bare `~`, and relative
      paths with two or more slashes become `[path]`.
- **What's dropped:**
  - IDs, `affected`, `containerIDs` and agent-root PIDs are never emitted.
  - Of action records, only time, action, `offered`, outcome, target kind and name, and project
    name are kept. `detail`, `shortID`, the image, `startTimeMicros` and `origin` are dropped.
  - Alerts are kept as time, title, observations, projects and suggestion. `Alert.rule` isn't
    read, so 4f making it optional won't break this file.
- **Anonymising:**
  - Real names become "Project A, B…, Z, AA…" in order of first appearance: the busiest moment's
    projects, then explanation projects, alert projects, timeline rows and actions (container
    compose projects included).
  - One case-insensitive, longest-first alternation applies it, with letters and digits as
    word characters. So `orbit-api-db-1` becomes `Project B-db-1` and no real name survives inside
    a container name.
  - The Docker VM and Unattributed rows keep their names.
  - Both formats render from one `RedactedIncident`, so Markdown and JSON can't disagree.
- **Markdown** has:
  - a title, When and Window lines, and a Summary with the context line;
  - Observations, one block per explanation with confidence, agents, timed observations and the
    recommendation;
  - Uncertainty (deduplicated), Alerts, a Timeline table and Actions. Any empty section says
    "None".
  - a footer naming what's left out and that heat isn't attributed per process.

  Observation, alert and action times have seconds; table rows are `HH:mm`.
- **JSON** is `{"format": "heatlens-incident", "version": 1, …}` with ISO-8601 dates. Numbers are
  rounded to one decimal, which also stops float noise like `449.99999999999994` from looking
  like a long digit run.

## Files
- Sources/HeatLensCore/Export/IncidentReport.swift — created
- Sources/HeatLensCore/Export/Redactor.swift — modified (see the first Note for Jarvis)
- Tests/HeatLensCoreTests/IncidentReportTests.swift — created
- handoffs/2026-10-28-1900-v2-p4h-incident-core.md — created

## Review fixes (second pass, 2026-10-28)
The review found leaks. All 8 items are fixed in `IncidentReport.swift`, each with tests:
1. **Event-only projects:** a timeline event's `projectName` is now in the alias list, so an
   event "secretproj-db-1 started" (project `secretproj`, named nowhere else) comes out as
   "Project C-db-1 started" in both formats. `Explanation.AgentTree` carries agent names
   (claude, codex) and no project, so it isn't aliased. No other field on the inputs names a
   project.
2. **PID spellings:** one `pidList` pattern drives both the parenthesised and the bare rule. It
   drops `PIDs 1, 2 and 3`, `pids 11, 22, 33`, `pid=123`, `ppid=77`, `PID: 123`, `(pids 4, 5 & 6)`,
   `(PID n)` and `PID n,`, case-insensitively. There's a parameterised test per spelling.
3. **Case variants:** names are lowercased before aliases are assigned, so `Foo`, `foo` and `FOO`
   share one alias. The lookup is `aliases[found.lowercased()]`, never a walk over the
   Dictionary. The alternation is sorted by length and then by name, so the pattern is the same
   on every run. The test checks two runs give identical output and that Markdown and JSON
   agree.
4. **Paths:** after a rooted or `~` path, each following space-separated piece that holds a `/`
   is swallowed too. So `/Users/other/My Project/sub/file.txt` and `~/Documents/a b/c` each
   become one `[path]`. Windows `C:\…` paths get the same treatment with `\`. One limit remains:
   a final spaced piece with no slash (`/Users/x/My Project`, ending there) still leaves that
   last word.
5. **Alias boundary:** a trailing run of digits now sits outside the match, so `heatlens2`
   becomes `Project A2`. `heatlensx` is a different word and is left alone.
6. **Markdown safety:** every text field has its newlines and tabs (plus VT, FF, NEL, LS, PS)
   collapsed to one space in the scrubber. That covers both formats, which keeps Markdown and
   JSON identical. `|` is still escaped in table cells. Placeholders are now `[path]`, `[id]`,
   `[user]`, `[secret redacted]`, `[redacted]` and `[arguments redacted]`; the `Sanitizer`'s
   `<…>` forms are converted.
7. **Margins:** `IncidentBuilder.clamped` turns a negative margin into 0, and NaN or ±∞ also
   into 0. The window filter is now a closure rather than a `ClosedRange`, so even bad dates
   can't trap.
8. **Non-finite numbers:** `IncidentBuilder.wholeNumber` replaces every `Int(Double)`. It gives 0
   for NaN and ±∞ and clamps at ±1e15. `tenths` (used for every JSON number and for `percent`
   and `cores`) does the same, so JSON never fails to encode. The test feeds NaN, ±∞ and 1e300
   in points, project points and a busiest-moment trigger. Markdown shows no "nan" or "inf",
   and the JSON decodes.

## Checks run
- `swift build`: Build complete, with no warnings from the new file.
- **First pass:**
  - `swift test --filter "IncidentReport|Redactor"`: three clean runs.
  - Full suite under the lock: 393 tests passed.
- **Second pass (review fixes):**
  - The `IncidentReport` suite now has 16 tests; with the RedactorTests suites, the filtered run
    is 33 tests.
  - `swift test --filter "IncidentReport|Redactor"`:
    - The first 2 of 5 runs failed only on the known RedactorTests timing test ("1,000
      processes … well under a second": 1.11 s and 1.17 s). The machine's load average was 26
      at the time, with mediaanalysisd at about 195 % CPU.
    - The next **three runs in a row passed** (33 tests, about 0.4 s each).
  - Full suite once, via
    `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`:
    **400 of 401 passed.** The one failure was that same timing test, at 1.59 s, with the
    whole suite running in parallel. As the brief says, I haven't changed that test.
    - My only edit to `Redactor.swift` makes two methods `fileprivate`; it doesn't touch the
      text or JSON report path that test times.
    - That tree also held the 4a worker's uncommitted edits.
  - `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- The fixture is synthetic: home `/Users/hlfixture` and made-up project names.
- **Not checked:** nothing in the app uses this yet (4i), so there's nothing to click through.

## Processes left running
none

## Notes for Jarvis
- **`Redactor.swift` is 3 words, not 1.** Making `Sanitizer` internal on its own doesn't compile:
  its `evidence(_:)` and `action(_:)` return the file-private `RedactedEvidence` and
  `RedactedAction` ("method must be declared fileprivate because its result uses a private
  type"). So both of those methods are now `fileprivate`, and nothing else changed. The incident
  code has its own `evidence` (`IncidentScrubber.evidence`).
- I added `timeZone: TimeZone = .current` to `incidentMarkdown(_:options:homeDirectory:)` so tests
  are deterministic. It's defaulted, so 4i calls it exactly as the plan wrote.
- **For 4i:**
  - Call `IncidentBuilder.incident(from: explanation | alert | peak, timeline: window, alerts:,
    explanations:, actions: ActionLog.shared.recent(...))`.
  - Preview with `Redactor.incidentMarkdown(incident, options:)`.
  - `Redactor.incidentLeftOut` is the list the footer names, if the sheet wants to show it.
- **Flaky test:** the RedactorTests timing test failed under load in this pass (see Checks run).
  Your pre-merge full-suite run may need a quiet machine or a rerun.
- **Suggested commit:** `feat(v2): Phase 4h — Incident, IncidentBuilder (±2 min window, ≤120 timeline rows) and redacted incident Markdown/JSON with optional Project A, B… anonymising`
