# AGENTS.md

Guidance for AI coding agents working on LiveIsland.

## What this is

LiveIsland is a macOS app (Swift, SwiftUI + AppKit, no package dependencies) that turns the notch into a Dynamic Island: now playing from any app, Claude Code and Codex sessions with their usage limits, calls, microphone and camera, AirPods and battery, timers and calendar. Its promises: **stay out of the way** (clicks pass through, nothing steals focus), **cost almost no CPU when closed**, **never lose or leak the user's data**.

## Layout

| Path | Responsibility |
|---|---|
| `Sources/LiveIslandCore/` | Testable logic with no UI: `JSONLScanner` (fast line and key scanning), `ClaudeTranscript`, `CodexRollout`, `UsageLedger` (incremental token ledger), `ClaudeLimits` (status line percentages), `ClaudeAccounts` (identities, `~/.claude.json` and credential edits, per-account limits, claude-swap's JSON), `NowPlaying`, `IslandActivity` (priorities, timers), `Format`, agent models |
| `Sources/LiveIsland/Accounts/` | Claude accounts: `AccountsMonitor` (the active account, limits per account, switching), `ClaudeLogins` (LiveIsland's own switch), `ClaudeCodeLocks` (Claude Code's lock protocol), `SecurityTool` (the Keychain through `/usr/bin/security`), `ClaudeSwapCLI` |
| `Sources/LiveIsland/Providers/` | Live sources: `NowPlayingProvider` (media adapter), `ScriptedPlayers` (Spotify, Music), `OutputVolume`, `AgentMonitor` (FSEvents + worker queue), `SessionHosts` (which app runs each agent, and jumping there), `SystemMonitor` (mic, camera, calls, battery, Bluetooth), `CalendarProvider` |
| `Sources/LiveIsland/App/` | `IslandModel` (all state, settings, what wins the notch), app entry, `liveisland://` links |
| `Sources/LiveIsland/Island/` | The panel window, compact and expanded island views, glass helpers |
| `Sources/LiveIsland/Settings/` | Settings window and the menu bar panel |
| `Sources/LiveIsland/Support/` | Process running, login item, artwork colors, Claude Code status line setup |
| `ThirdParty/mediaremote-adapter/` | Vendored now-playing adapter (BSD-3-Clause, see `UPSTREAM_COMMIT`); keep its license |
| `Tests/LiveIslandCoreTests/` | Swift Testing suites for `LiveIslandCore`; `RealDataBenchmark` is opt-in |
| `demo/` | README media (see "Demo media" below) |

## Build and verify

```bash
./scripts/test.sh                 # all tests (adds the Testing plugin path on Command Line Tools)
./scripts/build.sh                # → build/LiveIsland.app (builds the adapter with CMake once)
pkill -x LiveIsland; open build/LiveIsland.app
open "liveisland://open"          # open the island without the mouse
/usr/bin/log show --last 5m --predicate 'subsystem == "com.aissam.liveisland"'
LIVEISLAND_REAL_DATA=1 ./scripts/test.sh -c release --filter RealData   # time a read of the real transcripts
```

Measure CPU as CPU time over a minute, not `ps %cpu` (a decaying average that overstates bursts):

```bash
P=$(pgrep -x LiveIsland); ps -o time= -p $P; sleep 60; ps -o time= -p $P
```

Every change to `LiveIslandCore` needs tests, with fixtures shaped like real transcript lines (`Tests/LiveIslandCoreTests/Fixtures.swift`).

## Hard rules

- **No SwiftUI `@State`/`@Entry`**: they're macros whose plugin ships only with Xcode. Keep view state in `IslandModel` (`@Published`) or another `ObservableObject`.
- **Idle must be nearly free.** No `TimelineView(.animation)` or other per-frame work; use Core Animation-driven views (`ProgressView`, symbol effects) and `TimelineView(.periodic)` at 1 s or slower. Heavy work goes on the agent worker queue, never the main thread. The global mouse monitor must return early when the pointer is far from the notch.
- **Transcripts can be gigabytes.** Never re-read whole files: `UsageLedger` keeps byte offsets per file (and notices replaced or truncated files). Read only the tail of a session for its state.
- **Never script an app that isn't running**: AppleScript would launch it. The only exception is the user tapping an idle player's icon.
- **Don't block the main thread on the system**: use the asynchronous `NSWorkspace.open(_:withApplicationAt:configuration:)`, not `open(_:)`, which can wait seconds on a sandbox check.
- **Don't change the user's Claude Code setup on your own.** The status line lines are added only when the user clicks the button, after a backup.
- **Hardened runtime needs entitlements for privacy prompts** (`Resources/LiveIsland.entitlements`): without `com.apple.security.personal-information.calendars` or `com.apple.security.automation.apple-events`, macOS silently denies instead of asking. Add the entitlement and the `Info.plist` usage string together.
- **Claude logins are the user's most sensitive data.** Never log, print or display a token; tests use made-up values only. Switching stays off until the user picks it, and nothing ever switches on its own: only the user's tap calls `switchTo`. Replace only `claudeAiOauth` in Claude Code's credential item (the same item holds the user's MCP logins) and only `oauthAccount` in `~/.claude.json` (splice the raw text; never re-serialize the file). Hold Claude Code's locks (`ClaudeCodeLocks`) for the whole switch, save the outgoing account's newest login first, and roll back if a step fails. Write Keychain items with `/usr/bin/security` (hex on stdin), as Claude Code does, so reads stay prompt-free.
- **The window never resizes.** The panel is a fixed transparent canvas; the island's shape animates inside it, and clicks pass through everywhere outside the island.
- No new third-party dependencies.

## Demo media

`demo/` holds the README's GIF, video and screenshots, made from a full-screen recording (`recording.mov`, 4096×2648 on a scaled Retina display). Always drop the audio, and cut anything that shows private content (a terminal with a conversation, files on the desktop). Screen recordings have a variable frame rate, so cut with `trim` + `concat` rather than `select`.

```bash
ISLAND="crop=1300:640:1398:0"   # the island's region in the recording; adjust for a new one
ffmpeg -i recording.mov -an -filter_complex "[0:v]trim=4:16,setpts=PTS-STARTPTS[a];[0:v]trim=64:69,setpts=PTS-STARTPTS[b];\
[a][b]concat=n=2:v=1:a=0,$ISLAND,fps=12,scale=720:-1:flags=lanczos,split[x][y];\
[x]palettegen=max_colors=192:stats_mode=diff[p];[y][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 demo/demo.gif   # keep it under ~10 MB
ffmpeg -i recording.mov -an -vf "crop=2200:1430:1398:0,fps=30,scale=1100:-2:flags=lanczos" \
  -c:v libx264 -preset slow -crf 29 -pix_fmt yuv420p -movflags +faststart demo/demo.mp4
ffmpeg -ss 58.5 -i recording.mov -frames:v 1 -vf "crop=1260:620:1418:0" -q:v 3 demo/island-agents.jpg   # one per page
```

## Style

Match the surrounding code: small focused types, doc comments that explain *why*, plain user-facing wording.
