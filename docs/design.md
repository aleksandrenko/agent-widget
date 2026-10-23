# Agent Widget — agreed design (2026-10-23)

A desktop-level panel (own app, not WidgetKit: needs hover, glass and animation).

## Panel
- One glass panel, top-left of the desktop, 360 pt wide by default (drag the right edge: 300–720 pt), radius 20. Drag it from anywhere to move it; the position is remembered.
- Two layers: outer glass (blurred wallpaper + dark tint), inner darker layer behind the tasks
  (radius 14), so tasks read well and stand apart from the footer.
- Header strip, one 22 pt row: brand mark (lined up with the status squares, ~/.agent-widget/brand.svg or ✨) + brand name; right: person icon + full name as one text, then the pin (lined up with the GitHub icons).
- Still glow from the top-left corner over 80% of the width and 40% of the height: blue in the corner, violet right, teal and green below; fades out before its edges.
- Bottom edge = week bar: 2 pt, accent-colour fill, edge to edge, Mon–Fri 09:00–18:00, fills by the minute.
  Hover: day, time, % of the day, % of the week.

- Pin in the header (right of the name): pinned floats above every window (green pin), unpinned sits on the desktop.

## Menu bar
- Template icon: a ticket (rounded shape, a notch on each side, a small eye on the right), 18 × 13 pt like the keyboard-language icon; outlined while the panel is open, filled while it is closed.
- The eye blinks (lids close and open, every 3.5 s) while an agent waits for you or Slack has unread.
- App icon: minimal green binoculars (two rings, a bridge, two eyepiece ticks) on the dark glass tile.
- Any click opens a menu: Open / Hide / Close panel, About, summary lines (tasks · working · waiting, Slack, next meeting, e2e), pin, refresh now, move to this screen, quit.
- Header: ✕ after the pin closes the panel (remembered across restarts).

## Task row (one list, hairline separators, light hover on the whole row)
- 32 pt status square, icon only, glossy: light-to-dark gradient, light top edge, glow in its colour.
  Blue sparkles (stars light up in turn) working, orange waving hand (±18°) waits for me, green check done, slate moon no agent.
- Each row has a wash of its status colour from the left edge, fading out by ~60% of the width.
- Title (13 pt), below it Jira key · note (11 pt), below that a 150 pt, 2 pt stage bar:
  grey track, lighter grey fill. Stages: code, pushed, AI review, CI build, staging, prod.
  Hover: stage under the cursor and whether it's done, current or next.
- GitHub logo coloured by the PR's status, with its own light hover circle, tooltip explaining the
  colour, and its own click (the PR). Row click opens the Claude session. No Jira icon on rows.

## Footer (11 pt)
- `e2e` text, green/red by the last run of the configured e2e workflow; blinking round clock while one runs. Click → that run.
- PRs created week/month; Jira tickets open / closed this month (hidden without Jira).
- Right: calendar with today's meeting count. 10 min before a meeting: orange pill "3 · 4 мин";
  during one: red pill "3 · в среща" with a blinking dot. Click → meeting link, else Google Calendar.

## Slack (UI built; data source not decided, so it stays hidden)
- No layer of its own: rows sit on the outer glass under the tasks, with a hairline before the footer;
  shown only while there are unread DMs or mentions.
- Text-only rows, no leading icon: **name** (· #channel for a mention) · first line of the message, cut with "…".
- Right: small muted count badge, 14 pt tall, rose 32% background, light-rose 11 pt number.
- Click → that conversation in Slack.
- Names/text need a personal Slack user token; without one it's a single "Slack · N непрочетени" row from the Dock badge.
