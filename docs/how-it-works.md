# How it works

## Data flow
1. Every 15 s the app runs `collector/collect.py --local` (Claude sessions and the Slack badge, the last GitHub / Jira answers reused, well under a second); every minute it runs the full collector.
2. The collector gathers sessions, PRs, Jira, Slack and footer stats in parallel (one failing source never blanks the others; its error shows in a tooltip) and writes `~/.agent-widget/tasks.json`.
3. The app reloads the panel from that file. Meetings come from EventKit inside the app and refresh with the same timer, and on any calendar change.

## Claude sessions
Read from the Claude desktop app's session files (`~/Library/Application Support/Claude/claude-code-sessions`), with their transcripts in `~/.claude/projects`.

| Status | Rule |
|---|---|
| working | transcript written in the last 90 s, or a turn is open and the session was active in the last 30 min |
| waiting | the agent asked you something and you haven't replied: an `AskUserQuestion` without an answer, or a turn that ended with `wrap_up(blocked: true)` and no message from you since. The question is the row's note. |
| done | everything else. The app's own turn summary ("blocked", "needs action") is not used: it often flags things that don't need you. |

## Linking a session to a task
A session belongs to the first Jira key found in, in order (your `jira.projects` keys if set, otherwise any `ABC-123`):
1. its title, its branch and worktree name (as the app records them), its folder and the folder's git branch;
2. the keys **you typed** in it (not the reminders the harness adds to your messages), the branches it **pushed**, and the PRs it **opened** with `gh pr create`.

A session shows on its own ticket's row and on every ticket it opened a PR for.

Keys that only appear in tool output are ignored, so a session that merely *reads about* a ticket is not filed under it. Transcript scans are cached by file size in `~/.agent-widget/refs-cache.json`.

## Which tasks are shown
A task is shown while at least one of these is true:
- a session on it is **waiting** for you (last 24 h) or **working**;
- it has an **open PR**;
- a PR on it was **merged in the last 24 h** and is not on prod yet;
- its Jira ticket is in progress (one of `jira.activeStatuses`).

Order: waiting → working → no agent → done, failing stages first within each group, then most recent. At most 8 tasks.

## Stages
The stage of a task is the stage of its least advanced live PR.

| Stage | Reached when |
|---|---|
| 1. Code | a session is working on it, no PR yet |
| 2. Pushed | a PR exists (draft) |
| 3. AI review | the PR is open and not approved yet (*fails* if changes are requested) |
| 4. CI build | approved; CI running, or red / conflicting (*fails*) |
| 5. On staging | approved and green (waiting for merge), then merged |
| 6. On prod | the PR has your release bot's comment (`prodComment` in `config.json`) |

## Footer
- **e2e**: the workflow set in `config.json` → `e2e` (`repo`, `workflow`, and `titlePrefix` to pick one kind of run, e.g. the full-suite gate of release builds). Green or red by the last finished run; the clock blinks while one is running. The tooltip shows how many of the last 10 passed; a click opens the running run, or the last one.
- **Mobile**: `config.json` → `mobile`. The newest tag ending in `tagSuffix` (e.g. `v26.10.24-production`) is the release in the stores; its tagger date is when it shipped. The newest tag after it is the candidate. The clock blinks while a `promoteWorkflow` run is going; the phone's colour is the last finished run of `e2eWorkflow` on `e2eBranch`.
- **PRs**: GitHub search, `author:@me created:>=` the week's Monday / the month's 1st.
- **Meetings**: today's events with attendees that are not all-day, not *free*, where you are an attendee who hasn't declined (or the organiser), so meetings on calendars shared with you don't count. The number is the ones that haven't ended yet. Every minute the app asks the calendar accounts to sync, so moved or cancelled meetings drop off. The call link is the event URL, or the first Meet / Zoom / Teams link in its location or notes.

## Claude limits
Only a Claude session can read the plan limits, so a Claude scheduled task (`birdwatcher-usage`, every 15 minutes on weekdays 9:00–18:59) calls the app's usage tool and writes `~/.agent-widget/usage.json`. The collector passes it on; older than 3 hours it is marked stale and the bar turns grey.

## Slack
The number on Slack's Dock icon (`lsappinfo info -only StatusLabel Slack`) is your unread DMs plus mentions. A bare `•` means only channel unreads and is ignored.

## Menu bar
The number next to the owl is how many want you: agents waiting for your answer plus unread Slack DMs and mentions. Nothing waiting, no number.

## Monthly score
The header's dots show the month's engineering KPI (the Normalized Score, REV-12239): score = 10 × √work points, work points = 0.5 × item points + counted lines ÷ 450 + 0.5 × merged PRs. Filled dots are the share of the target reached; faint ones what the pace adds by the month end; green, amber or red by whether the month end reaches the target. Hover for the details.

GitHub answers a busy month (every PR with its files) in a minute or more, so `collect.py --score` runs in the background every 30 minutes and writes `~/.agent-widget/score.json`; the regular runs only read it. Set the target and the GitHub org in `config.json` → `score` (`target`, default 230; `org`).

## Minimize
The header's – hides the tasks and Slack; the header, the footer and the week and month bars stay.

## Files
| Path | What |
|---|---|
| `~/.agent-widget/tasks.json` | the collector's output, read by the app |
| `~/.agent-widget/collect.log` | collector errors |
| `~/.agent-widget/refs-cache.json` | transcript scan cache |
| `defaults read com.nikolay.agentwidget` | panel position and pin state |
| `~/.agent-widget/config.json` | your settings (see `config.example.json`) |
| `~/.agent-widget/brand.svg` | optional header mark |
