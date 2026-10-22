# AGENTS.md

Guidance for AI coding agents working on LiveIsland.

## What this is

LiveIsland is a macOS app (Swift, SwiftUI + AppKit, no package dependencies) that turns the notch into a Dynamic Island: now playing from any app, Claude Code and Codex sessions with their usage limits, calls, microphone and camera, AirPods and battery, timers and calendar. Its promises: **stay out of the way** (clicks pass through, nothing steals focus), **cost almost no CPU when closed**, **never lose or leak the user's data**.

## Layout

| Path | Responsibility |
|---|---|
| `Sources/LiveIslandCore/` | Testable logic with no UI: `JSONLScanner` (fast line and key scanning), `ClaudeTranscript`, `CodexRollout`, `UsageLedger` (incremental token ledger), `ClaudeLimits` (status line percentages), `NowPlaying`, `IslandActivity` (priorities, timers), `Format`, agent models |
| `Sources/LiveIsland/Providers/` | Live sources: `NowPlayingProvider` (media adapter), `ScriptedPlayers` (Spotify, Music), `OutputVolume`, `AgentMonitor` (FSEvents + worker queue), `SessionHosts` (which app runs each agent, and jumping there), `SystemMonitor` (mic, camera, calls, battery, Bluetooth), `CalendarProvider` |
| `Sources/LiveIsland/App/` | `IslandModel` (all state, settings, what wins the notch), app entry, `liveisland://` links |
| `Sources/LiveIsland/Island/` | The panel window, compact and expanded island views, glass helpers |
| `Sources/LiveIsland/Settings/` | Settings window and the menu bar panel |
| `Sources/LiveIsland/Support/` | Process running, login item, artwork colors, Claude Code status line setup |
| `ThirdParty/mediaremote-adapter/` | Vendored now-playing adapter (BSD-3-Clause, see `UPSTREAM_COMMIT`); keep its license |
| `Tests/LiveIslandCoreTests/` | Swift Testing suites for `LiveIslandCore`; `RealDataBenchmark` is opt-in |

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
- **The window never resizes.** The panel is a fixed transparent canvas; the island's shape animates inside it, and clicks pass through everywhere outside the island.
- No new third-party dependencies.

## Style

Match the surrounding code: small focused types, doc comments that explain *why*, plain user-facing wording.
