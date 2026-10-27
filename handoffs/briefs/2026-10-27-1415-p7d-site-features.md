# Phase 7d: site copy for 1.1.0 (ports, AI agent, command line)
worker: opencode
model: <placeholder>
effort: low
started: 2026-10-27 13:52 · terminal: 587594cc-e865-455c-a748-35164496922a

## Goal
HeatLens 1.1.0 is released. Add its features to the landing page `site/index.html`. Edit only that file. Done means:
1. In the "What it shows" section (`site/index.html` around lines 214–236), `.columns` holds 3 `<div>` columns today. Add exactly **3 more** columns after the existing three (the CSS grid is 3 wide, so they form a second row). Copy the existing column markup exactly: `<h3>`, `<p>`, and a `<div class="sample">` with `<span class="k">` labels. Use synthetic sample values only.
   - **"Who holds each port"**: after a scan, a Ports section shows which process and which project holds each listening TCP port, for example `:3000` held by `next-server` in `~/Projects/portfolio-demo`. Click a row to inspect it, then use the usual actions. Sample: `<span class="k">:3000</span> next-server · PID 23014<br><span class="k">Scope</span> loopback<br><span class="k">Project</span> ~/Projects/portfolio-demo`
   - **"Ask your AI agent"**: HeatLens ships a read-only MCP server. Settings → Connect to an AI agent copies the setup command for Claude Code or Codex, and then you can ask your agent "why is my Mac hot?". The agent can run a scan or list ports, but it can't stop anything, and reports are always redacted. Sample: `<span class="k">Tools</span> scan · ports<br><span class="k">Mode</span> Read-only, redacted`
   - **"From the terminal"**: the same tool works in a terminal. Sample: `heatlens scan --seconds 5<br>heatlens ports --json` (inside the sample div; you may wrap commands in `<code>`).
2. In the FAQ (`<div class="faq">`, around line 307), add one `<details>` after "Does it run in the background?", in the same markup:
   - summary: `Does connecting an AI agent send my data anywhere?`
   - answer, one paragraph: HeatLens itself still makes no network connections; the MCP server runs on your Mac over standard input and output. But whatever the agent receives, it sends to its own model provider, as with anything else you show it. That's why the reports it gets are redacted: personal paths are replaced, and specific network addresses are left out. You choose whether to connect one, and you can remove it with `claude mcp remove heatlens`.
3. Change nothing else: no CSS, no other sections, no meta tags.

## Context
- Prior handoff: `handoffs/merged/2026-10-27-1142-p4b-landing-page.md` (the site's structure and tone). Write plain, concrete sentences like the existing columns, with no marketing superlatives.
- Pattern to copy: the existing `.columns > div` blocks and `<details>` blocks in `site/index.html`.

## Scope
- May touch: `site/index.html`
- Must not touch: everything else. Don't run git commands that change state.
- Shared files: none

## Done when
`python3 -c "import html.parser,sys; html.parser.HTMLParser().feed(open('site/index.html').read())"` runs without error. `grep -c '<h3>' site/index.html` is 3 higher than before (note both numbers). The handoff lists the exact new headings.

## Phase
One phase.

## Checks
The commands under "Done when".

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
