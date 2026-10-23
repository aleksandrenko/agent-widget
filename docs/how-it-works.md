# How it works

## Data flow
1. Every 15 s the app runs `collector/collect.py --local` (Claude sessions only, the last GitHub / Jira / Slack answers reused, well under a second); every minute it runs the full collector.
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
- **PRs**: GitHub search, `author:@me created:>=` the week's Monday / the month's 1st.
- **Tickets**: Jira, tickets moved to one of `jira.doneStatuses`, or resolved, since then.
- **Meetings**: today's events with attendees that are not all-day, not *free*, and not declined by you. The call link is the event URL, or the first Meet / Zoom / Teams link in its location or notes.

## Slack
The number on Slack's Dock icon (`lsappinfo info -only StatusLabel Slack`) is your unread DMs plus mentions. A bare `•` means only channel unreads and is ignored.

## Files
| Path | What |
|---|---|
| `~/.agent-widget/tasks.json` | the collector's output, read by the app |
| `~/.agent-widget/collect.log` | collector errors |
| `~/.agent-widget/refs-cache.json` | transcript scan cache |
| `defaults read com.nikolay.agentwidget` | panel position and pin state |
| `~/.agent-widget/config.json` | your settings (see `config.example.json`) |
| `~/.agent-widget/brand.svg` | optional header mark |
