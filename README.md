<div align="center">

<img src="docs/icon.png" width="150" alt="LiveIsland icon">

# LiveIsland

### Your Claude Code work doesn't stop at a usage limit.

**A Dynamic Island for the Mac's notch that moves Claude Code to your next account before the one in use runs out, through claude-swap, and shows what's playing, who's working, and how much room each account has left.**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)
![Tests](https://img.shields.io/badge/tests-95%20passing-success)

<br>

<img src="demo/island-accounts.png" width="760" alt="The island's Accounts tab: claude-swap with automatic switching on, which just moved from main to Work; three accounts with their 5-hour and weekly use and when each resets">

<sub>Main reached 88% of its 5-hour limit, so claude-swap moved Claude Code to Work, and every running session followed.</sub>

**[Install](#install)** · **[Accounts with claude-swap](#accounts-with-claude-swap)** · **[Screenshots](#screenshots)** · **[Features](#features)**

</div>

---

## The problem

You hand Claude Code a long job and walk away. Forty minutes later it has stopped:

> You've hit your session limit · resets 3:45pm

Nothing happens until you come back, sign in to another account and type "continue". If you pay for more than one account, the others sit idle the whole time. And the notch, a black bar in the middle of your screen, tells you none of this.

## The solution

LiveIsland turns the notch into a Dynamic Island that keeps an eye on your work for you.

- **It switches before you hit the wall.** LiveIsland runs [claude-swap](https://github.com/realiti4/claude-swap), which checks all your accounts every minute and moves Claude Code to the one with the most room when the account in use nears its limit. Every session follows within about 30 seconds: Terminal, VS Code, anywhere. Nothing stops, so there's nothing to resume.
- **Everything at a glance.** Which agent is working or waiting for you, how much of each account's 5-hour and weekly limits is left and when it resets, what's playing, with a waveform that moves to the music.
- **It stays out of the way.** It opens on hover, clicks pass straight through, and it uses under 1% of one core when closed.

### Three steps

| 1. Install claude-swap | 2. Add your accounts | 3. Turn on automatic switching |
|---|---|---|
| **Settings › Accounts › Install** puts it in place with uv, and **Update** keeps it current | **Add and Sign In** opens Claude Code's own sign-in for each one, then adds it to claude-swap. LiveIsland never sees a login | **Switch automatically**: claude-swap moves to the next account before the one in use runs out. Watch it from the island or the console |

## Screenshots

<table>
  <tr>
    <td align="center" width="33%">
      <img src="demo/island-media.png" alt="Media page: Spotify's track with its cover glow, a live waveform beside the title, scrubber, controls and volume"><br>
      <sub><b>Media</b><br>Any player, a real waveform, glow from the cover</sub>
    </td>
    <td align="center" width="33%">
      <img src="demo/island-agents.png" alt="Agents page: Claude Code sessions with states, and rings for the 5-hour and weekly limits of Claude Code and Codex"><br>
      <sub><b>Agents</b><br>Sessions, states, real usage limits</sub>
    </td>
    <td align="center" width="33%">
      <img src="demo/island-activity.png" alt="Activity page: timer presets, calendar, battery, AirPods, microphone and camera tiles"><br>
      <sub><b>Activity</b><br>Timer, calendar, battery, devices, privacy</sub>
    </td>
  </tr>
  <tr>
    <td align="center" colspan="3">
      <img src="demo/island-split.png" width="560" alt="The closed island shared by two things: Claude Code on the left, the music's waveform on the right"><br>
      <sub><b>In the notch</b><br>Claude and the music share it, like the iPhone</sub>
    </td>
  </tr>
  <tr>
    <td align="center" colspan="3">
      <img src="demo/settings-agents.png" width="560" alt="Settings window, AI Agents page: agent toggles and sound"><br>
      <sub><b>Settings</b><br>Everything, in one window</sub>
    </td>
  </tr>
</table>

## Features

**Accounts that don't run out**
- [claude-swap](https://github.com/realiti4/claude-swap), installed, updated and run from LiveIsland: every account's 5-hour and weekly use, its reset times and when it will run out at this pace
- **Automatic switching** before the account in use runs out, to the one with the most room, with your own switch points, strategy and cooldown
- Every claude-swap command one click away: switch, keep out of rotation, rename, switch point, order, remove, add
- **Add and Sign In**: a new account signs in with Claude Code's own sign-in and lands in claude-swap by itself
- A **console** with every command LiveIsland ran, its output, and every automatic switch as it happens; type any other `cswap` command there

**Now Playing**
- Works with any app that plays audio or video: Spotify, Music, browsers, podcasts…
- Reads **Spotify and Music directly** too, so a paused Spotify stays one tap away while a video plays in the browser. Switch players from the island
- A **real waveform** that moves with the music: bass pulses in the middle, treble at the edges, in the cover's colors (macOS 14.2+)
- Artwork with a **glow in the cover's colors**, drag to scrub, ±15 s, previous / play / next
- **Up Next** from Music's playlist, and **Recently Played** for Spotify and Music: tap a track to play it again
- System volume and output device right under the player
- Music or Spotify not open? Their icons are there; tap to open and play

**AI agents**
- Every **Claude Code** and **Codex** session: working (with a timer), needs you, done, idle
- **Jump to the session** in the app it runs in: VS Code, Cursor, Antigravity or Windsurf (the right window), Terminal or iTerm2 (the exact tab)
- Copy the command that resumes a session
- **Usage limits as rings**: Claude Code's real 5-hour and weekly percentages (one click to set up, see below), Codex's 5-hour and weekly limits, tokens this window and today
- **Several Claude and Codex accounts**: each one's limits side by side, an alert in the notch when the account in use runs out, and one-tap switching, also from the menu bar
- Optional sound when an agent finishes or stops to ask you something

**Calls, devices and the rest**
- Call timer for FaceTime, Zoom, Teams, Discord, WhatsApp, Slack and more
- Which app is using the **microphone**, and whether the **camera** is on
- **AirPods** battery (left, right, case) when they connect; charging, and time left on battery
- Quick **timers**, your next **calendar** events, and a heads-up in the notch 10 minutes before
- The most important thing wins the notch: a call beats an agent that needs you, which beats music
- **Two things at once**: while music plays, an agent or a timer shares the notch with the waveform, like the iPhone

**Everyday use**
- Opens on hover (or click), closes when you move away; clicks pass straight through everywhere else
- **Your tab order**: put Media, Agents, Activity and Accounts in the order you like (Settings › Island). Beside a wide notch, the tabs show icons only rather than slide under the camera
- **Software Update** in Settings: see what's new and update in one click. It checks GitHub once a day (you can turn that off) and never installs on its own
- Settings window, menu bar panel, Open at Login, `liveisland://` links for Shortcuts
- Liquid Glass on macOS 26+, with a material fallback on earlier systems
- On Macs without a notch, the island sits at the top of the screen

## Claude Code limits

Claude Code shares its 5-hour and weekly percentages only with its status line. In **Settings › AI Agents**, click **Add to My Status Line**: LiveIsland adds three lines to your status line script, after it reads its input, and keeps a copy of the original next to it (`*.liveisland-backup`). The lines save the percentages to `~/.claude/liveisland-limits.json`, which the island reads.

Prefer to do it yourself? The lines are in [`scripts/claude-statusline-snippet.sh`](scripts/claude-statusline-snippet.sh). They go inside the status line script; typed into a terminal they do nothing. Without them, the island still shows Claude Code's tokens for the current 5-hour window and for today, counted from its transcripts.

## Accounts with claude-swap

<table>
  <tr>
    <td align="center" width="50%">
      <img src="demo/settings-accounts.png" alt="Settings, Accounts page: claude-swap 0.29.0, automatic switching on with its switch points and strategy, and three accounts with their use, Switch buttons and menus"><br>
      <sub><b>Settings › Accounts</b><br>claude-swap, its automatic switching, every account</sub>
    </td>
    <td align="center" width="50%">
      <img src="demo/console.png" alt="The console: cswap auto starting, a switch from main to work, every account out until 14:30, a crash and LiveIsland starting it again"><br>
      <sub><b>The console</b><br>Every command, switch and restart, as text</sub>
    </td>
  </tr>
</table>

[claude-swap](https://github.com/realiti4/claude-swap) (MIT) keeps a login for each of your Claude accounts and puts the one in use in place for Claude Code. LiveIsland runs it, shows what it says, and never reads a login itself.

**Set it up** in **Settings › Accounts**:

1. **Install.** If claude-swap isn't there, **Install** runs `uv tool install claude-swap` (pipx, or Homebrew's uv, when uv is missing). **Update to …** appears when claude-swap offers a newer version.
2. **Add your accounts.** **Add the Account Claude Code Uses Now** adds the one you're signed in to. For each other account, type a name and click **Add and Sign In**: Terminal opens on Claude Code's own `claude auth login`, in a folder of its own under `~/.claude-accounts`, so the account you use now stays as it is; once you've signed in, LiveIsland runs `cswap add` for it. Don't sign those folders out later: claude-swap holds the same logins, and signing out cancels them.
3. **Switch automatically.** LiveIsland runs `cswap auto --json` while it's open, starts it again if it ever stops, and shows each switch in the notch. Set the switch point for the 5-hour and the weekly limit, how long to wait between switches, and whether to pick the account with the most room or the soonest weekly reset.

The island's **Accounts** tab lists claude-swap's accounts with their use and reset times, a **Switch** button on each (★ marks the one with the most room), the **Auto** switch, and a button to the console. Each account's menu in Settings keeps it out of automatic rotation, renames it, sets its own switch point, moves it up or down, or removes it.

**The console** shows every command LiveIsland ran with its full output and exit code, and every automatic switch, refusal and restart as it happens (tick *Show every check* for the minute-by-minute checks). Type any other `cswap` command below it: it runs claude-swap directly, never through a shell. **Dashboard** opens claude-swap's own dashboard in Terminal. `liveisland://settings/accounts/console` opens it.

Anthropic doesn't say whether switching your own accounts automatically is allowed: its Consumer Terms forbid "bypassing any of our systems or protective measures", and Claude Code's limits assume "ordinary, individual usage". Automatic switching stays off until you turn it on. Accounts that bill an API key stay out of rotation unless you change claude-swap's settings.

**Codex accounts** switch through LiveIsland itself: the Accounts tab has a Claude Code | Codex switch, and **Settings › AI Agents** has *Switch Codex accounts with LiveIsland* (off by default). LiveIsland keeps a copy of each Codex login in its own folder, readable only by you, the same way Codex keeps its own in `~/.codex/auth.json`, and puts it in place when you tap Switch. Add accounts with `codex login`; avoid `codex logout`, which cancels the login.

## How it works

| What | Where it comes from |
|---|---|
| Now playing (any app) | MediaRemote, through the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter): since macOS 15.4 only Apple-signed processes may read it, so the adapter runs inside `/usr/bin/perl` |
| Spotify and Music | Their own "track changed" notifications, and AppleScript for details and controls. LiveIsland never scripts an app that isn't running, since that would open it |
| Claude Code and Codex | Their session files (`~/.claude/projects`, `~/.codex/sessions`), watched with FSEvents. Transcripts can be gigabytes, so only new bytes are read |
| Where a session runs | The process table: each agent's folder and terminal, and the app above it |
| Claude accounts | claude-swap's `cswap list --json` (every account's use), `cswap auto --json` (each switch as it happens) and its other commands; who Claude Code is logged in as from `~/.claude.json`. LiveIsland never reads a login |
| Codex accounts | Who's logged in, and the plan, from `~/.codex/auth.json`; limits from the `rate_limits` Codex writes in each session; logins (only when you turn on Codex switching) as private copies of that file in `~/Library/Application Support/LiveIsland` |
| Microphone, camera, calls | Core Audio's process list and CoreMediaIO. Only *whether* they're in use, never what they hear or see |
| Waveform | A Core Audio process tap on what the Mac plays (macOS 14.2+), only while music plays and the bars are on screen. It only listens: the sound is never changed, muted, recorded or stored, just measured band by band |
| Battery, AirPods | IOKit power notifications; IOBluetooth and `system_profiler` for AirPods levels |
| Calendar | EventKit, read only |
| Updates | This repository's latest GitHub release, at most once a day. A new version must match its SHA-256, be LiveIsland at the version promised and pass `codesign --verify` before it replaces the app |

## Performance

Measured on an M4 Pro with Claude Code and Codex running and Spotify playing:

| | CPU |
|---|---|
| Island closed | under 1% of one core |
| Island open | about 9% while it's on screen (drawing) |
| First read of 460 Claude Code transcripts (2 GB) | about 3 s, once, in the background |
| Checking them again | 16 ms |

Nothing animates frame by frame unless you can see it: spinners and waveforms are drawn by Core Animation, clocks tick once a second, and mouse moves far from the notch are ignored.

## Install

**Download** the latest release (macOS 14 or later, Apple silicon and Intel) and open it, in one Terminal command:

```bash
curl -fL https://github.com/charonova/LiveIsland/releases/latest/download/LiveIsland.zip -o /tmp/LiveIsland.zip \
  && mkdir -p ~/Applications && ditto -xk /tmp/LiveIsland.zip ~/Applications && open ~/Applications/LiveIsland.app
```

LiveIsland isn't notarized by Apple yet (that needs a paid developer account), so a copy downloaded in a browser gets "Apple could not verify LiveIsland" the first time. Installed with the command above, it opens right away. If you downloaded [the zip](https://github.com/charonova/LiveIsland/releases/latest) in a browser, unzip it, move LiveIsland to Applications, open it once, then click **Open Anyway** in **System Settings › Privacy & Security**.

After that, new versions install from **Settings › Software Update**.

**Build it yourself** instead, with the Xcode Command Line Tools and CMake (`brew install cmake`, for the media adapter):

```bash
git clone https://github.com/charonova/LiveIsland.git
cd LiveIsland
./scripts/install.sh   # builds, copies to ~/Applications and launches
```

macOS will ask for:

- **Calendar**, for your next events
- **Bluetooth**, for AirPods battery
- **Automation** for Spotify and Music (now playing and controls), and for Terminal or iTerm2 the first time you jump to a session there
- **System audio recording**, for the live waveform, the first time music plays. Without it the island shows the animated symbol; you can turn the waveform off in Settings › Media
- Nothing for accounts: claude-swap keeps the Claude logins in your Keychain itself, and Codex logins are private files in LiveIsland's own folder

Everything works without any of them; the matching feature just stays empty.

## Updates

**Settings › Software Update** shows the version you have, and whether a newer one is out on GitHub with what's new. **Update Now** downloads it, checks it (its SHA-256, that it's LiveIsland at the version promised, and its signature), puts it in place of the running app and reopens it. LiveIsland looks for a new version once a day; turn that off on the same page. Until LiveIsland is notarized by Apple, macOS may ask again for its permissions after an update.

## Tests

```bash
./scripts/test.sh                                   # all tests
LIVEISLAND_REAL_DATA=1 ./scripts/test.sh -c release --filter RealData   # read your own transcripts, timed
```

The tests cover the transcript and rollout parsers, the incremental usage ledger (appends, truncation, replaced files, duplicate messages), 5-hour windows, limit notices that go stale, Claude Code's status line limits, now-playing stream updates, the waveform's bands (bass and treble in the right bars, a beat shows as movement, a quiet track moves like a loud one, silence stays flat), activity priorities, the tab order (kept as tabs come and go), software updates (versions compared number by number, GitHub's release answer, checksums), timers, session resume commands and editor window matching. For accounts: filing each status line report under the right account after a switch, limits from refused requests, the account with the most room (never one nearly full), and claude-swap: its accounts list, settings, version and update notices, every kind of `auto` event (unknown ones kept), the list LiveIsland shows (exactly claude-swap's), and typed commands split without a shell, with the ones that need a terminal turned away. For Codex: who a login belongs to (from its ID token), ChatGPT plan names, Codex limits in the account book, and listing Codex accounts apart from Claude ones.

## Automation

| Link | Action |
|---|---|
| `liveisland://open` · `close` | Open or close the island |
| `liveisland://open/accounts` | Open it on a page: `media`, `agents`, `activity` or `accounts` (`accounts/codex` for the Codex list) |
| `liveisland://timer/5` | Start a 5-minute timer |
| `liveisland://update` · `update/install` | Check for a new version, and install it |
| `liveisland://settings` · `settings/agents` | Open Settings, or one of its pages: `general`, `island`, `media`, `agents`, `accounts`, `updates`, `about` (`accounts/console` for claude-swap's console) |

## Privacy

LiveIsland has no analytics and no accounts. Transcripts, calendar events and everything else stay on your Mac. The waveform measures the sound in memory and never records or keeps it. Its only network requests download Spotify's cover art, from the address Spotify itself gives, and ask GitHub once a day whether a newer LiveIsland is out (turn that off in Settings › Software Update). claude-swap asks Anthropic for each account's use, as it does on its own; LiveIsland runs it and keeps its output only in memory, for the console.

## Credits

Now playing uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by ungive (BSD-3-Clause), vendored in `ThirdParty/`. Account switching is [claude-swap](https://github.com/realiti4/claude-swap) by realiti4 (MIT), installed separately. Claude Code, Codex, Spotify and the other apps named here belong to their owners; LiveIsland isn't affiliated with them.

## License

[MIT](LICENSE) © 2026 Aissam Irhir
