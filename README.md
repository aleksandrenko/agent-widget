# TheWatcher

**Everything your AI agents and your tickets are doing, on one glass panel on your Mac desktop.**

TheWatcher sits on your wallpaper (or, pinned, above every window) and answers one question at a glance: *what needs me right now?* It joins your Claude Code sessions, your pull requests, your Jira tickets, your Slack, your e2e runs and your calendar into one short list, one row per task.

<p align="center">
  <img src="docs/screenshots/default.png" width="420" alt="TheWatcher on the desktop: six tasks, two Slack messages, the footer and a meeting in 4 minutes">
</p>

| In a meeting | A quiet afternoon |
|---|---|
| <img src="docs/screenshots/meeting.png" width="360" alt="The panel during a meeting"> | <img src="docs/screenshots/quiet.png" width="360" alt="The panel with three tasks and nothing waiting"> |

---

## What you see

### One row per task
Sessions, PRs and tickets that share a Jira key (`WEB-1201`) are one task. Each row shows:

- **Agent status**: the coloured square.
  - 🟧 **Orange waving hand**: an agent asked you a question and is waiting for your answer. These rows always come first.
  - 🟦 **Blue sparkles**, lighting up in turn: an AI agent is working right now.
  - 🟩 **Green check**: the agent finished.
  - ⬛ **Slate moon**: nobody is working on it, but something is still open (a PR, a ticket).
- **Title, Jira key and a one-line note**: what the agent is asking you, or which PR it is.
- **Stage bar**: how far the work has got.
  `code → pushed → AI review → CI build → on staging → on prod`
  Hover any point of the bar to see that stage and whether it is done, running or next.
- **GitHub icon**, coloured by the PR's status: grey draft, light blue waiting for AI review, yellow CI running, red CI failing or a conflict, green ready to merge, violet merged. Hover it to see what its colour means; click it to open the PR.

Click a row to jump straight into that Claude session.

### Slack
Unread direct messages and mentions appear under the tasks, one line each, and disappear once read. Click a line to open Slack.

### Footer
- **`e2e`**: green or red by the last run of the e2e workflow you configure (for example the full suite every release build goes through), with a blinking clock while one is running. Hover it for how many of the last 10 passed; click it to open the run.
- **Browser icon + `2h`**: how long ago the last release of the repo you configure (`prod.repo`, for example the portal) reached production, from its newest `prod-N` release; the same blinking clock while the next one is going out. Hover it for the release and its first changes; click it to open the release notes.
- **Phone icon + `1d`**: how long the newest mobile version has been in the stores (`mobile.repo`, from its newest `…-production` tag). The phone is green or red by the last run of the mobile e2e workflow; the same blinking clock while a release candidate is being promoted. Hover it for when that tag was cut, the newest `-rcN` tag after it and the e2e results; click it to open the repo's tags (the mobile app uses tags, not GitHub releases).
- **PRs**: PRs you opened this week / this month.
- **Tickets**: your open Jira tickets / tickets done this month. Appears once Jira answers (run `setup-jira-token.sh`).
- **Claude limit**: how much of your Claude 5-hour session limit is used, a small bar that fills up green → orange → red; hover for the %. Filled by a Claude scheduled task (`birdwatcher-usage`, every 15 min on weekdays), because only a Claude session can read the plan limits. Greyed out when the reading is over 3 hours old, so you can tell the task has stopped.
- **Calendar**: how many of today's meetings are still ahead (the one you're in counts, finished ones don't). Ten minutes before a meeting it turns into an orange `3 · 4 мин` pill; during a meeting it turns into a red `3 · в среща` pill. Click it to join the call.
- **Week bar**: the panel's bottom edge fills in your accent colour from Monday 09:00 to Friday 18:00. Hover it for the day and the week's progress.

### Size, modules and themes
- **Resize** the panel from any edge or corner; the cursor turns into the matching arrows over it. Until you change its height by hand it fits its tasks; after that it keeps your height, the tasks scroll between the header and the footer, and a **see all** button over the fade at the bottom fits it to all of them again (so does a double-click on the top or bottom edge). The header shows how many tasks there are: `TheWatcher (8)`.
- **Modules** in the menu bar menu turn parts of the panel on and off: e2e tests status, portal last release, mobile last release, my GitHub PRs, my monthly Jira tickets, Claude limits, my calendar meetings, Slack alerts. A module that is off isn't fetched either. To add one: a case in `Module` (`App/Model.swift`), a check where the panel draws it, and its name in the collector's `OFF` check if it fetches something.
- **Themes** in the same menu: **Payhawk Dark Green** (the glass you see above), **Payhawk Day** (the same panel light, with dark text) and **Native** (flat grey, like the system's widgets). A team's `brand.accent` in `config.json` sets the accent in every theme.

### Updates
Once a day the app asks GitHub for the newest release. When it is newer than yours, a notification says so (click it to download the DMG) and **⬆︎ New version … — download** shows at the top of the menu bar menu. **Check for updates**, next to **About**, asks right away. To update, open the DMG and drag TheWatcher into Applications over the old one.

### Explorer
The **?** between the pin and the ✕ starts a tour of the panel: a bubble next to each part says what it is, with **Back** / **Next** to move along and ✕ to stop. Parts the panel isn't showing right now (no Slack, no tasks) are skipped.

### Pin and the menu bar icon
Double-click the header to refresh everything now; a faint spinner next to the name turns while it does (and shows, still, while you hover the header). The pin in the header moves the panel above every window, including full-screen apps. Click it again to send the panel back to the desktop.

The ✕ in the header hides the panel; while it's hidden nothing updates, and it refreshes the moment you open it again. The owl in the menu bar shows its state, eyes open while the panel is open and shut while it is hidden; it blinks while someone wants you (an agent waiting for your answer, or unread Slack). Click it for a menu with **Open / Hide panel** and **Pin above all windows** right under it (pinning also shows the panel and brings it back on screen, the way back to a panel lost under other apps), a short summary (tasks, who's waiting for you, Slack, the next meeting, e2e), **Language** (Български / English), **Modules**, **Themes**, **Setup…**, **Check for updates** and **About**. To quit, use Activity Monitor or `pkill TheWatcher`; open it again from Spotlight, Apps or the Desktop icon.

---

## Use cases

**"Which of my agents is stuck on me?"**
You run five Claude Code sessions in parallel. Instead of clicking through each one, look for the orange hands at the top of the panel. Each one has the agent's question in its note line, e.g. `say 'merge it' for #4512`. One click opens that session.

**"What is left before this ships?"**
A task's stage bar shows where it stopped: the AI reviewer, CI, waiting for merge, or on staging and waiting for the prod release. A red GitHub icon means CI is failing or there is a conflict.

**"My agent stopped but the work isn't done."**
A task with an open PR stays on the panel with the moon icon after its session ends, so a PR waiting for CI never gets forgotten.

**"Am I about to be late?"**
The calendar pill turns orange ten minutes before a meeting and red once it has started. Click it to join.

**"Did someone ping me?"**
The Slack lines appear only while there are unread DMs or mentions, so an empty panel means nobody is waiting for you there.

**"How did the week go?"**
The footer counts this week's PRs and closed tickets against the month, and the green week bar shows how much of the working week is gone.

**"I need it in front of me while I code."**
Pin it. It floats above your editor; unpin it when you want your screen back.

---

## Install

1. Download **[TheWatcher.dmg](https://github.com/aleksandrenko/agent-widget/releases/latest/download/TheWatcher.dmg)**, open it and drag TheWatcher into Applications.
2. Open TheWatcher. The first time, macOS says it can't check the app (it isn't notarized): open *System Settings → Privacy & Security*, scroll down and click **Open Anyway**.
3. The setup window walks you through the rest: Python and the GitHub CLI if they're missing, your team's settings link, and the optional Jira token, calendar and Claude limit.

Requirements: macOS 15 or later, a GitHub account with the `gh` CLI (setup offers to install and sign in).

### From source
```bash
git clone git@github.com:aleksandrenko/agent-widget.git ~/agent-widget
~/agent-widget/build.sh            # build for this Mac, install to /Applications, start
~/agent-widget/build.sh --release  # universal dist/TheWatcher.dmg
```
Needs the Xcode Command Line Tools (`xcode-select --install`); no Xcode project or licence.

### Configuration
Everything specific to your company lives outside the app, in `~/.agent-widget/` (Payhawk's is in [`teams/payhawk/`](teams/payhawk/)):

| File | What |
|---|---|
| `config.json` | Written by setup from your team's link, or a copy of [`config.example.json`](config.example.json). A team link is an https JSON file `{"config": {…config.json…}, "brandSVG": "<svg…>"}`; a gist link works. `team`: your team's name (shown in setup). `brand`: the accent colour. `jira`: your site, project keys, and which statuses count as active. `e2e`: the GitHub repo, workflow (file name or id) and run-title prefix to watch. `mobile`: the mobile app's repo, the suffix of its store-release tags, its promote workflow and its e2e workflow and branch. `prodComment`: the text your release bot comments on a PR once it is in production. |
| `brand.svg` | Optional. Your logo mark for the header, drawn in the accent colour. Without it the header shows ✨. |

Leave a section empty and that part of the panel stays empty (no Jira icons, no `e2e`).

### First run
- **Calendar**: macOS asks once for calendar access. Your work Google account must be added in *System Settings → Internet Accounts* for meetings to show up. The panel shows what the Mac's Calendar app has; `open -g agentwidget://snapshot` writes every event of today, its calendar and why it is or isn't counted to `~/.agent-widget/meetings.json`.
- **Jira**: store an API token in the keychain:
  ```bash
  ~/agent-widget/setup-jira-token.sh
  ```
  Create the token at <https://id.atlassian.com/manage-profile/security/api-tokens>. Without it, the Jira icons stay grey and the ticket count shows `–`.
- **Slack**: nothing to set up. The count comes from the number on Slack's Dock icon.

---

## How it works

```
┌─────────────────────────────┐  every 60 s   ┌──────────────────────────────┐
│  TheWatcher.app (SwiftUI)  │ ────────────▶ │ collector/collect.py         │
│  · glass panel on desktop   │               │  · Claude session files      │
│  · calendar via EventKit    │ ◀──────────── │  · gh: PRs, reviews, CI, e2e │
│  · hover tooltips, clicks   │ tasks.json    │  · Jira REST (keychain token)│
└─────────────────────────────┘               │  · Slack Dock badge          │
                                              └──────────────────────────────┘
```

- The **collector** reads the Claude desktop app's session files, asks GitHub for your open and recently merged PRs, asks Jira for your tickets, groups everything by Jira key and writes `~/.agent-widget/tasks.json`.
- The **app** runs the collector every minute and redraws the panel. It reads meetings straight from the Mac's calendars.

Full rules, covering how sessions are linked to tickets, which tasks are shown and how stages are worked out, are in [docs/how-it-works.md](docs/how-it-works.md). The visual spec is in [docs/design.md](docs/design.md).

---

## Development

```bash
python3 -m unittest collector/test_collect.py   # collector test cases
./build.sh                                      # build, install, restart
./tools/screenshots.sh                          # re-render docs/screenshots from docs/demo
open -g "agentwidget://refresh"                 # collect now
open -g "agentwidget://snapshot"                # write the live panel to ~/.agent-widget/panel.png
```

**Demo mode**: `/Applications/TheWatcher.app/Contents/MacOS/TheWatcher --demo docs/demo/default` shows sample data and touches nothing else: no collector, no login item, no saved position. Add `--snapshot out.png` to write a picture of the panel and quit. The README screenshots are made this way, so they never show real work.

### Layout
```
App/                 SwiftUI app: panel, tooltips, calendar, demo mode
  Resources/         Jira and GitHub marks (SVG)
collector/           collect.py and its test cases
docs/                design spec, how it works, demo data, screenshots
tools/               screenshot compositor, app icon (icon.swift → App/AppIcon.icns)
build.sh             build, install, start
config.example.json  settings template for ~/.agent-widget/config.json
setup-jira-token.sh  Jira token to the keychain
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No panel after `build.sh` | It may be on another display. Run `defaults delete com.nikolay.agentwidget panelTopLeft`, then `./build.sh`. |
| Jira icons grey, ticket count `–` | Set `jira.site` in `config.json`, then run `./setup-jira-token.sh` (the token may have expired). |
| Calendar shows `–` | Calendar access was denied: *System Settings → Privacy & Security → Calendars → TheWatcher*. |
| Calendar shows `0` | Add your work Google account in *Internet Accounts*. |
| Nothing updates | Check `~/.agent-widget/collect.log`, or run `python3 collector/collect.py` by hand. |
| A session sits under the wrong task | The Jira key comes from the session title, folder, branch, or the keys you typed in it. Mention the right key once in the session. |

## Roadmap
- Slack names and message previews (needs a personal Slack token; today it shows the unread count).
- Prod detection beyond the release-comment check for services outside the standard pipeline.
- Settings for working hours, how many tasks to show, and the meeting warning time.
