# Phase 10f: click-only "Check for updates…" in Settings (ships as 1.2.1)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1800-p10f-check-for-updates.md
## What the user asked
A click-only update check: no automatic, background or launch check, no timer, no setting. One GET to GitHub when the user clicks; it tells them and opens the release page, installs nothing. Plus the "no network" copy edits in README and site.
## What changed
- Core: `ReleaseInfo.parse` reads GitHub's latest-release JSON (keeps `tag_name` minus a leading `v`, `html_url`, `draft`, `prerelease`) and throws on drafts, prereleases, malformed JSON (e.g. a rate-limit body) and any `html_url` not starting with `https://github.com/gorock007/heatlens/releases/`. `UpdateCheck.status` compares numerically per component (missing = 0, so 1.2 == 1.2.0; 1.10.0 > 1.9.0); a tag that isn't dot-separated ASCII digits (`2.0.0-beta`, `latest`, empty) gives `.upToDate`.
- App: `UpdateChecker` (`@MainActor @Observable`, states idle/checking/upToDate/available/failed). One `GET https://api.github.com/repos/gorock007/heatlens/releases/latest` on an ephemeral `URLSession` (no cache, no cookie storage), headers `User-Agent: HeatLens/<CFBundleShortVersionString>` and `Accept: application/vnd.github+json`, 10 s timeout, no query or other data. Non-200, network error or a parse rejection → "Couldn't check for updates." Nothing calls `check()` except the button.
- Settings: new row above the "Settings are stored…" caption: "HeatLens <version>" + "Check for updates…" (shows "Checking…" and disables while running), caption "Contacts GitHub only when you click.", then "You're up to date." / "HeatLens x.y.z is available." + Download (opens `html_url`) / "Couldn't check for updates." + Releases page (opens `https://github.com/gorock007/heatlens/releases`). Both via `NSWorkspace.shared.open`. No raw error text is ever shown.
- Copy: README line 87 and the two `site/index.html` phrases, exactly as the brief worded them. Nothing else on the site changed.
## Files
- Sources/HeatLensCore/Update/UpdateCheck.swift — created
- Tests/HeatLensCoreTests/UpdateCheckTests.swift — created
- App/UpdateChecker.swift — created
- App/SettingsView.swift — modified
- README.md — modified
- site/index.html — modified
- handoffs/2026-10-27-1800-p10f-check-for-updates.md — created
## Checks run
- `swift build`: Build complete. `swift test`: 186 tests in 35 suites passed, including the new "Update check" suite (7 tests, 16 cases: real-shape parse, `v` strip, draft/prerelease rejected, 4 foreign URLs rejected incl. http and `heatlens-evil`, rate-limit/HTML bodies rejected, 1.10.0 > 1.9.0, 1.2 == 1.2.0 both ways, older/equal latest up to date, 6 malformed tags up to date). Tests use inline fixture JSON; none touch the network. `Update/` is picked up by the `HeatLensCore` target with no Package.swift change.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`, no warnings from the new files.
- Live, Debug app (`open -n .build/xcode/Build/Products/Debug/HeatLens.app`, Info.plist 1.2.0; `/Applications/HeatLens.app` untouched), driven via System Events accessibility:
  - Before the click, after launch and again with Settings open: `lsof -nP -i -a -p <pid>` listed no sockets (exit 1).
  - After clicking Check for updates: the row read "You're up to date." `nettop -p <pid> -m tcp` showed one flow `192.168.0.10:60187<->4.237.22.34:443` (state Closed; `dig api.github.com` → 4.237.22.34), ~6.5 KB in / 2.6 KB out across two clicks. lsof polling at 200 ms missed it because the connection closes as soon as the session is invalidated.
  - Screenshot of the row: /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/407dadcc-94df-474a-bcf5-f69fc7b84283/scratchpad/p10f-settings-update-row.png
- `grep -n "No network access" site/index.html README.md`: only the new site wording (README no longer contains the phrase).
- Not checked live: the "available" and "failed" states (no newer release exists and I didn't take the network down). Both are covered by the core tests and are plain state → text mapping in the view.
## Processes left running
none (Debug app stopped by its PID; `jarvis leftovers --mine` reports nothing)
## Questions for the user
none
## Notes for Jarvis
- Version bump to 1.2.1 (`project.yml`, `Sources/HeatLensCLI/Arguments.swift`) left to you as the brief says. After the bump, the Debug build would report 1.2.1 vs. latest v1.2.0 → "You're up to date." until v1.2.1 is published.
- The site copy change needs a site redeploy along with the release.
- Suggested commit: `feat(core,app): click-only "Check for updates…" in Settings; one GET to GitHub only when clicked, opens the release page, installs nothing; README/site network wording (Phase 10f)`
