# AGENTS.md

Guidance for AI coding agents working on LiveIsland.

## What this is

LiveIsland is a macOS app (Swift, SwiftUI + AppKit, no package dependencies) that turns the notch into a Dynamic Island: now playing from any app, Claude Code and Codex sessions with their usage limits, calls, microphone and camera, AirPods and battery, timers and calendar. Its promises: **stay out of the way** (clicks pass through, nothing steals focus), **cost almost no CPU when closed**, **never lose or leak the user's data**.

## Layout

| Path | Responsibility |
|---|---|
| `Sources/LiveIslandCore/` | Testable logic with no UI: `JSONLScanner` (fast line and key scanning), `ClaudeTranscript`, `CodexRollout`, `UsageLedger` (incremental token ledger), `ClaudeLimits` (status line percentages), `ClaudeAccounts` (identities, `~/.claude.json` and credential edits, per-account limits, claude-swap's JSON), `CodexAccounts` (who a Codex login belongs to, ChatGPT plans), `NowPlaying`, `AudioLevels` (the waveform's bands), `IslandActivity` (priorities, timers), `Format`, agent models |
| `Sources/LiveIsland/Accounts/` | Claude accounts: `AccountsMonitor` (the active account, limits per account, switching, for Claude Code and Codex), `ClaudeLogins` (LiveIsland's own switch), `CodexLogins` (Codex's), `ClaudeCodeLocks` (Claude Code's lock protocol), `SecurityTool` (the Keychain through `/usr/bin/security`), `ClaudeSwapCLI` |
| `Sources/LiveIsland/Providers/` | Live sources: `NowPlayingProvider` (media adapter), `ScriptedPlayers` (Spotify, Music), `OutputVolume`, `AudioLevelMeter` (the waveform's listen-only audio tap), `AgentMonitor` (FSEvents + worker queue), `SessionHosts` (which app runs each agent, and jumping there), `SystemMonitor` (mic, camera, calls, battery, Bluetooth), `CalendarProvider` |
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
- **Claude logins are the user's most sensitive data.** Never log, print or display a token; tests use made-up values only. Switching stays off until the user picks it, and nothing ever switches on its own: only the user's tap calls `switchTo`. Replace only `claudeAiOauth` in Claude Code's credential item (the same item holds the user's MCP logins) and only `oauthAccount` in `~/.claude.json` (splice the raw text; never re-serialize the file). Hold Claude Code's locks (`ClaudeCodeLocks`) for the whole switch, save the outgoing account's newest login first, and roll back if a step fails. Write Keychain items with `/usr/bin/security` (hex on stdin), as Claude Code does, so reads stay prompt-free. Codex logins are copies of `~/.codex/auth.json`, kept like Codex keeps it: private files (0600) in a 0700 folder, written to a temporary file and renamed. Numbers land on an account only from a session started after the latest switch, or when they match that account's reset times: sessions keep the login they started with.
- **The waveform only listens.** Its Core Audio tap is unmuted and its private aggregate device outputs silence, so the sound is never changed. It runs only while something plays and bars are on screen, and stops 4 s after. Levels go straight to the bars' Core Animation layers 30 times a second, never through SwiftUI state. Ad-hoc builds change signature, so macOS asks for system audio recording again after each rebuild.
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

Screenshots of the running app don't need a recording. Open each page with a link and capture only LiveIsland's window, which keeps its transparency (find the window number with `CGWindowListCopyWindowInfo`, owner "LiveIsland"). Capture within a second of opening: the island closes when the pointer passes over it and leaves. Then crop to the island and blur emails (the Accounts tab, and the account name on Agents):

```bash
open "liveisland://open/accounts"; sleep 0.8; screencapture -x -o -l<window> accounts.png   # accounts/codex for the Codex list
ffmpeg -i accounts.png -vf "crop=1300:640:110:0" cropped.png
B="boxblur=luma_radius=14:luma_power=4:chroma_radius=14:chroma_power=4"   # radius < half the band's height
ffmpeg -i cropped.png -filter_complex "[0:v]format=gbrap,split[base][a];[a]crop=280:36:138:266,${B}[e];\
[base][e]overlay=138:266,format=rgba" demo/island-accounts.png   # one band per email row (108 px apart); ${B}, not $B[..] in zsh
```

Blur email addresses before anything leaves the Mac (the Accounts tab and Settings show them). Blur each email line while the tab is open, and the whole name column while rows re-sort after a switch, so no address slides past mid-animation; find those moments with `select='gt(scene,0.05)'` on the column. Then check the column frame by frame:

```bash
ON="between(t,14.6,31.2)"                     # when the Accounts tab is open
MOVE="between(t,17.3,17.85)+between(t,23.05,23.55)"   # when its rows move
BLUR="boxblur=luma_radius=18:luma_power=3:chroma_radius=9:chroma_power=3"
ffmpeg -i recording.mov -an -filter_complex "[0:v]crop=2200:1430:1398:0,split=3[base][e1][col];\
[e1]crop=306:44:132:203,${BLUR}[b1];[col]crop=306:310:132:164,boxblur=30:3:30:3[bc];\
[base][b1]overlay=132:203:enable='${ON}'[v1];[v1][bc]overlay=132:164:enable='${MOVE}'" clean.mp4   # one band per row
```

## Style

Match the surrounding code: small focused types, doc comments that explain *why*, plain user-facing wording.
