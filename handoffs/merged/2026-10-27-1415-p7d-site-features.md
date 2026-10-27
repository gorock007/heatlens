# Phase 7d: site copy for 1.1.0 (ports, AI agent, command line)
status: done
agent: opencode big-pickle
brief: handoffs/briefs/2026-10-27-1415-p7d-site-features.md
## What the user asked
Add HeatLens 1.1.0 features to site/index.html: add 3 columns to "What it shows", add 1 FAQ item.
## What changed
Added "Who holds each port", "Ask your AI agent", and "From the terminal" columns with sample markup; added FAQ about AI agent data sharing. Replaced "From the terminal" paragraph per fix.
## Files
- site/index.html — modified
## Checks run
python3 -c "import html.parser,sys; html.parser.HTMLParser().feed(open('site/index.html').read()); print('ok')" (ok). grep -c '<h3>' was 6 before; now 9 (+3). Verified exact headings added.
## Processes left running
none
## Questions for the user
none
## Notes for Jarvis
Fix applied: updated paragraph under <h3>From the terminal</h3> to the exact specified text. Only site/index.html modified. Handoff saved as requested.
