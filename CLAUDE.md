@AGENTS.md

## Claude Code notes

- Trust `swift build` over SourceKit's single-file "Cannot find … in scope" noise.
- Terminal usually can't take screenshots (no Screen Recording permission); ask the user for one to check the UI.
- Your own session shows up in the island while you work on it: a "working" Claude Code session is expected, not a bug.
- Each new ad-hoc-signed build may need Calendar, Bluetooth and Automation permissions granted again.
- `pkill -x LiveIsland` quits it cleanly (it handles SIGTERM and stops the media adapter); a leftover adapter from a crash is cleaned up at the next launch.
