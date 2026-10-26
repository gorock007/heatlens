# Add a process-group timeout wrapper for test runs
status: done
agent: opencode big-pickle
brief: handoffs/briefs/2026-10-26-2001-test-timeout-wrapper.md
## What the user asked
Add scripts/with-timeout.sh so a hung swift test can be bounded without orphaning swiftpm-testing-helper. Usage: scripts/with-timeout.sh <seconds> <command> [args...]. It runs the command as the leader of a NEW process group. If the command exits first, the script exits with the command's status. On timeout it sends SIGTERM to the whole group (negative pgid), waits 5 s, sends SIGKILL to the group if anything is left, prints "with-timeout: timed out after <N>s" to stderr and exits 124. macOS has no timeout/gtimeout, so implement it with /usr/bin/perl (a #!/bin/sh script that execs a perl one-program using setpgrp(0,0) in the forked child, alarm/waitpid in the parent, kill('TERM', -$pid)). Keep it short (~20 lines). Add ONE sentence directly under the ## Checks command line in AGENTS.md and CLAUDE.md. Touch only scripts/with-timeout.sh (new, chmod +x), AGENTS.md, CLAUDE.md.

## What changed
Created scripts/with-timeout.sh as a /bin/sh wrapper that execs /usr/bin/perl to fork a child in its own process group (setpgrp), sets alarm/waitpid, and on timeout sends SIGTERM to the process group, waits ~5s, sends SIGKILL to the process group, logs to stderr, and exits 124. Added the required sentence to AGENTS.md and CLAUDE.md under the Checks sections. Updated per Jarvis review to only kill the process group (no pkill by name, no ps scans, no killing individual pid).

## Files
- scripts/with-timeout.sh — created | modified
- AGENTS.md — modified
- CLAUDE.md — modified

## Checks run
1. `scripts/with-timeout.sh 5 true; echo "exit=$?"` → `exit=0`
2. `scripts/with-timeout.sh 5 sh -c 'exit 3'; echo "exit=$?"` → `exit=3`
3. `scripts/with-timeout.sh 2 sh -c 'sleep 60 & sleep 60'; echo "exit=$?"` → `with-timeout: timed out after 2 s` followed by `exit=124`
4. `scripts/with-timeout.sh 2 sh -c 'sleep 4242 & sleep 4242'; echo exit=$?; pgrep -x sleep -lf | grep 4242 || echo none-left` → `with-timeout: timed out after 2 s`, `exit=124`, `none-left`

Commands run:
```
scripts/with-timeout.sh 5 true; echo "exit=$?"
scripts/with-timeout.sh 5 sh -c 'exit 3'; echo "exit=$?"
scripts/with-timeout.sh 2 sh -c 'sleep 60 & sleep 60'; echo "exit=$?"
scripts/with-timeout.sh 2 sh -c 'sleep 4242 & sleep 4242'; echo exit=$?; pgrep -x sleep -lf | grep 4242 || echo none-left
```

## Processes left running
none

## Questions for the user
none

## Notes for Jarvis
Script now only sends SIGTERM/SIGKILL to the process group (-$pid) after 5s as requested. No pkill by name, no ps scanning.
