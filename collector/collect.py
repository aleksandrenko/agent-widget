"""Collects the tasks for the Agent Widget panel: Claude sessions, my PRs and my Jira tickets,
grouped into one card per task by the Jira key (ABC-123) found in titles, branches and folders.

Settings (Jira site and projects, e2e workflow, brand) come from ~/.agent-widget/config.json; see
config.example.json. Without them those parts of the panel stay empty.
Writes ~/.agent-widget/tasks.json and prints `changed` or `same`.

    python3 collect.py           # everything
    python3 collect.py --local   # sessions only, last GitHub/Jira/Slack answers reused
"""
import base64, concurrent.futures as cf, datetime as dt, glob, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

HOME = os.path.expanduser('~')
OUT_DIR = os.path.join(HOME, '.agent-widget')
OUT = os.path.join(OUT_DIR, 'tasks.json')
SESSIONS = os.path.join(HOME, 'Library/Application Support/Claude/claude-code-sessions')
TRANSCRIPTS = os.path.join(HOME, '.claude/projects')
CONFIG_FILE = os.environ.get('AGENT_WIDGET_CONFIG') or os.path.join(OUT_DIR, 'config.json')
DEFAULTS = dict(
    brand=dict(name='Agent Widget', accent='#3DDC84'),
    jira=dict(site='', projects=[], activeStatuses=['In Progress', 'In Review'], doneStatuses=['Done']),
    e2e=dict(repo='', workflow='', titlePrefix=''),
    prodComment='deployed to production',
)


def load_config():
    config = json.load(open(CONFIG_FILE)) if os.path.exists(CONFIG_FILE) else {}
    return {k: {**v, **config.get(k, {})} if isinstance(v, dict) else config.get(k, v) for k, v in DEFAULTS.items()}


CONFIG = load_config()
JIRA = CONFIG['jira']['site'].rstrip('/')
ENV = {**os.environ, 'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'}
NOW = time.time()
RECENT_HOURS = 8
WAITING_DAYS = 2
MERGED_DAYS = 4
MAX_TASKS = 8
WAITING_SHOWN_HOURS = 24
MERGED_SHOWN_HOURS = 24
# Your Jira project keys if configured; otherwise any ABC-123 that isn't a well-known look-alike.
NOT_KEYS = r'(?!(?:UTF|ISO|HTTP|SHA|RFC|TLS|ES|MD|CVE|GPT|X)-)'
KEY = re.compile(r'\b(' + '|'.join(map(re.escape, CONFIG['jira']['projects'])) + r')-\d{1,7}\b' if CONFIG['jira']['projects']
                 else r'\b' + NOT_KEYS + r'[A-Z][A-Z0-9]{1,9}-\d{1,7}\b', re.I if CONFIG['jira']['projects'] else 0)
PR_REF = re.compile(r'#(\d{3,6})\b')
PR_URL = re.compile(r'github\.com/[\w.-]+/([\w.-]+)/pull/(\d+)')
REFS_CACHE = os.path.join(OUT_DIR, 'refs-cache.json')
REMOTE_CACHE = os.path.join(OUT_DIR, 'remote-cache.json')
_refs = json.load(open(REFS_CACHE)) if os.path.exists(REFS_CACHE) else {}

# Stages, in order. A task sits at one of them; 6 means all done (on prod).
STAGES = ['code', 'pushed', 'aiReview', 'ci', 'staging', 'prod']


def sh(args, timeout=30):
    r = subprocess.run(args, capture_output=True, text=True, env=ENV, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[-300:])
    return r.stdout


def keys_in(*texts):
    return [m.group(0).upper() for t in texts if t for m in KEY.finditer(t)]


def branch_of(path, cache={}):
    if path not in cache:
        try:
            cache[path] = sh(['git', '-C', path, 'rev-parse', '--abbrev-ref', 'HEAD'], timeout=5).strip()
        except (RuntimeError, OSError, subprocess.TimeoutExpired):
            cache[path] = ''
    return cache[path]


INJECTED = re.compile(r'<(system-reminder|command-[\w-]+|local-command-[\w-]+|pasted_content[^>]*)>.*?</\1\b[^>]*>', re.S)


def typed_text(content):
    """What the person typed in a user message: no tool results, and none of the reminders the
    harness adds to the message (memory, skills), which mention tickets the person never typed."""
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list) and not any(p.get('type') == 'tool_result' for p in content):
        texts = [p.get('text', '') for p in content if p.get('type') == 'text']
    else:
        return None
    return INJECTED.sub(' ', ' '.join(texts)) if texts else None


def transcript_refs(path):
    """From a session transcript: the Jira key it works on (keys I typed, branches it pushed), the PRs it
    opened, and the question it is waiting on, if any: an unanswered AskUserQuestion, or a turn that ended
    with wrap_up(blocked) and no reply since."""
    try:
        size = os.path.getsize(path)
        if _refs.get(path, [None])[0] == size and len(_refs[path]) == 4:
            return _refs[path][1], [tuple(p) for p in _refs[path][2]], _refs[path][3]
        lines = open(path, encoding='utf8', errors='replace').read().splitlines()
    except OSError:
        return [], [], None
    keys, prs, creating, questions, ask = [], set(), set(), {}, None
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        msg = entry.get('message') or {}
        content = msg.get('content')
        if msg.get('role') == 'user' and not entry.get('isMeta'):
            text = typed_text(content)
            if text is not None:
                keys += keys_in(text)
                questions, ask = {}, None  # I replied: nothing is pending any more
        for part in content if isinstance(content, list) else []:
            if part.get('type') == 'tool_use':
                name, args = part.get('name', ''), part.get('input') or {}
                cmd = str(args.get('command') or '')
                if re.search(r'git (push|checkout -b|switch -c)|gh pr create', cmd):
                    keys += keys_in(cmd)
                if 'gh pr create' in cmd:
                    creating.add(part.get('id'))
                if name == 'AskUserQuestion':
                    questions[part.get('id')] = ((args.get('questions') or [{}])[0].get('question') or 'Има въпрос към теб')
                elif name.endswith('wrap_up') and args.get('blocked'):
                    ask = args.get('ask') or args.get('recap') or 'Чака отговор от теб'
            elif part.get('type') == 'tool_result':
                questions.pop(part.get('tool_use_id'), None)
                if part.get('tool_use_id') in creating:
                    prs |= {(repo, int(n)) for repo, n in PR_URL.findall(json.dumps(part.get('content')))}
    counts = {}
    for k in keys:
        counts[k] = counts.get(k, 0) + 1
    pending = next(iter(questions.values()), None) or ask
    result = sorted(counts, key=lambda k: -counts[k])[:1], sorted(prs), pending
    _refs[path] = [size, *result]
    return result


def sessions():
    written = {}
    for d in os.scandir(TRANSCRIPTS):
        if d.is_dir():
            for f in os.scandir(d.path):
                if f.name.endswith('.jsonl'):
                    written[f.name[:-6]] = (f.stat().st_mtime, f.path)
    rows = []
    for f in glob.glob(os.path.join(SESSIONS, '*/*/local_*.json')):
        try:
            s = json.load(open(f))
        except (OSError, ValueError):
            continue
        if s.get('isArchived'):
            continue
        # The transcript file is also touched by compaction and notes, so it only says "working".
        last = max(s.get('lastActivityAt') or 0, s.get('latestUserFrameAt') or 0) / 1000
        wrote, transcript = written.get(s.get('cliSessionId'), (0, None))
        summary = s.get('postTurnSummary') or {}
        in_turn = (s.get('latestUserFrameAt') or 0) > (s.get('lastTurnEdgeAt') or 0)
        current = s.get('postTurnSummaryFor') == s.get('lastAssistantUuid')  # summary is about the last turn
        talked_about, linked, question = transcript_refs(transcript) if transcript else ([], [], None)
        # The app writes a summary once a turn ends; until the latest turn has one, the agent is still on it.
        finished = current or not in_turn
        if 'postTurnSummaryFor' in s:
            working = not finished and NOW - max(last, wrote) < 1800
        else:  # sessions from before turn summaries
            working = NOW - wrote < 90
        if working:
            status = 'working'
        elif question:  # the agent asked you something and you haven't answered
            status = 'waiting'
        else:
            status = 'done'
        age = NOW - last
        if (status == 'done' and age > RECENT_HOURS * 3600) or (status == 'waiting' and age > WAITING_DAYS * 86400):
            continue
        cwd = s.get('cwd') or ''
        detail = question or summary.get('status_detail') or ''
        keys = keys_in(s.get('title'), s.get('branch'), s.get('worktreeName'), cwd,
                       branch_of(cwd) if os.path.isdir(cwd) else '') or talked_about
        rows.append(dict(
            id=s['sessionId'], title=s.get('title') or os.path.basename(cwd) or 'Session', status=status,
            detail=detail, last=last, url='claude://code/continue?session=' + s['sessionId'], keys=keys,
            prs=[int(n) for n in PR_REF.findall(detail)] + [n for _, n in linked] + ([s['prNumber']] if s.get('prNumber') else []),
        ))
    return rows


PR_FIELDS = 'number title url isDraft state mergedAt headRefName repository { name }'
OPEN_QUERY = '''query($q: String!) { search(query: $q, type: ISSUE, first: 40) { nodes { ... on PullRequest {
  %s reviewDecision mergeable
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
  reviews(last: 5) { nodes { state } } } } } }''' % PR_FIELDS
MERGED_QUERY = '''query($q: String!) { search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest {
  %s comments(last: 3) { nodes { body } } } } } }''' % PR_FIELDS


def graphql(query, q):
    for attempt in range(3):  # the search API answers a heavy query with an occasional 502
        try:
            return json.loads(sh(['gh', 'api', 'graphql', '-f', 'query=' + query, '-f', 'q=' + q]))['data']['search']['nodes']
        except RuntimeError:
            if attempt == 2:
                raise
            time.sleep(2)


def pr_stage(n):
    """(stage index, 'now' | 'wait' | 'fail', github state) for one PR."""
    if n['state'] == 'MERGED':
        if any(CONFIG['prodComment'] in c['body'] for c in n['comments']['nodes']):
            return 6, 'wait', 'prod'
        return 5, 'wait', 'merged'
    ci = (((n['commits']['nodes'] or [{}])[0].get('commit') or {}).get('statusCheckRollup') or {}).get('state')
    if n['isDraft']:
        return 1, 'now', 'draft'
    approved = n['reviewDecision'] == 'APPROVED' or any(r['state'] == 'APPROVED' for r in n['reviews']['nodes'])
    if n['reviewDecision'] == 'CHANGES_REQUESTED':
        return 2, 'fail', 'changes'
    if not approved:
        return 2, 'now', 'review'
    if n['mergeable'] == 'CONFLICTING' or ci in ('FAILURE', 'ERROR'):
        return 3, 'fail', 'fail'
    if ci in ('PENDING', 'EXPECTED'):
        return 3, 'now', 'ci'
    return 4, 'wait', 'ready'


def prs():
    since = (dt.date.today() - dt.timedelta(days=MERGED_DAYS)).isoformat()
    rows = []
    nodes = graphql(OPEN_QUERY, 'is:pr is:open author:@me archived:false') + \
        graphql(MERGED_QUERY, f'is:pr is:merged author:@me merged:>={since}')
    for n in nodes:
        if n:
            stage, state, gh = pr_stage(n)
            merged = dt.datetime.fromisoformat(n['mergedAt'].replace('Z', '+00:00')).timestamp() if n.get('mergedAt') else None
            rows.append(dict(number=n['number'], repo=n['repository']['name'], url=n['url'], title=n['title'], merged=merged,
                             stage=stage, stageState=state, github=gh, keys=keys_in(n['title'], n['headRefName'])))
    return rows


def week_month():
    today = dt.date.today()
    return (today - dt.timedelta(days=today.weekday())).isoformat(), today.replace(day=1).isoformat()


def pr_counts():
    week, month = week_month()
    count = lambda since: int(sh(['gh', 'api', '-X', 'GET', 'search/issues', '-f', f'q=is:pr author:@me created:>={since}',
                                  '-q', '.total_count']))
    return dict(week=count(week), month=count(month))


def e2e():
    """The configured e2e workflow (e.g. the full suite each release build goes through): last result,
    how many of the last 10 passed, and how many run now. None when no e2e workflow is configured."""
    e2e_cfg = CONFIG['e2e']
    if not (e2e_cfg['repo'] and e2e_cfg['workflow']):
        return None
    runs = json.loads(sh(['gh', 'run', 'list', '-R', e2e_cfg['repo'], '--workflow', str(e2e_cfg['workflow']), '-L', '60',
                          '--json', 'status,conclusion,displayTitle,createdAt,url']))
    full = [r for r in runs if r['displayTitle'].startswith(e2e_cfg['titlePrefix'])]
    running = [r for r in full if r['status'] != 'completed']
    done = [r for r in full if r['status'] == 'completed']
    last = done[0] if done else None
    recent = done[:10]
    return dict(ok=bool(last) and last['conclusion'] == 'success', last=last and last['displayTitle'],
                lastAt=last and last['createdAt'], url=(running[0] if running else last or {}).get('url'),
                running=len(running), passed=sum(r['conclusion'] == 'success' for r in recent), recent=len(recent))


def slack():
    """Unread DMs + mentions from the number on Slack's Dock icon ("•" alone means only channel unreads)."""
    out = subprocess.run(['lsappinfo', 'info', '-only', 'StatusLabel', 'Slack'], capture_output=True, text=True).stdout
    match = re.search(r'"label"="(\d+)"', out)
    if not match or int(match.group(1)) == 0:
        return []
    return [dict(id='slack', name='Slack', channel=None, text='непрочетени лични съобщения и споменавания',
                 count=int(match.group(1)), url='slack://open')]


def keychain(service):
    try:
        return sh(['security', 'find-generic-password', '-a', os.environ.get('USER', ''), '-s', service, '-w']).strip()
    except RuntimeError:
        return ''


def jira(extra_keys):
    if not JIRA:
        raise RuntimeError('Jira not configured')
    email, token = keychain('jira_email'), keychain('jira_api_token')
    if not (email and token):
        raise RuntimeError('no Jira token')
    headers = {'Authorization': 'Basic ' + base64.b64encode(f'{email}:{token}'.encode()).decode(), 'Accept': 'application/json'}
    get = lambda path: json.load(urllib.request.urlopen(urllib.request.Request(JIRA + path, headers=headers), timeout=20))
    try:
        get('/rest/api/3/myself')  # search answers an expired token with an empty list, not a 401
    except urllib.error.HTTPError as e:
        raise RuntimeError('Jira token expired' if e.code == 401 else f'Jira {e.code}')
    statuses = lambda names: ', '.join(f'"{n}"' for n in names)
    jql = f'assignee = currentUser() AND status in ({statuses(CONFIG["jira"]["activeStatuses"])})'
    if extra_keys:
        jql = f'({jql}) OR key in ({",".join(sorted(extra_keys))})'
    data = get('/rest/api/3/search/jql?' + urllib.parse.urlencode(dict(jql=jql, fields='summary,status', maxResults=100)))
    issues = {i['key']: dict(title=i['fields']['summary'], status=i['fields']['status']['name'], url=JIRA + '/browse/' + i['key'])
              for i in data.get('issues', [])}
    week, month = week_month()
    closed = lambda since: len(get('/rest/api/3/search/jql?' + urllib.parse.urlencode(dict(maxResults=100, fields='status', jql=(
        f'assignee = currentUser() AND (status changed to ({statuses(CONFIG["jira"]["doneStatuses"])}) after "{since}" '
        f'OR resolved >= "{since}")')))).get('issues', []))
    return issues, dict(week=closed(week), month=closed(month))


def jira_state(status):
    s = status.lower()
    if 'block' in s:
        return 'blocked'
    if 'review' in s:
        return 'review'
    if 'staging' in s:
        return 'staging'
    if s in ('done', 'closed', 'released', 'resolved', 'on production'):
        return 'done'
    if 'progress' in s:
        return 'progress'
    return 'todo'


def short_title(pr_title):
    return re.sub(r'^\w+(\([^)]*\))?:\s*(' + KEY.pattern + r'[:\s]*)?', '', pr_title, flags=re.I).strip() or pr_title


def build(sess, pulls, issues, jira_error):
    tasks = {}

    def task(key):
        return tasks.setdefault(key, dict(key=key, sessions=[], prs=[]))

    by_number = {p['number']: p for p in pulls}
    for p in pulls:
        task(p['keys'][0] if p['keys'] else f"pr:{p['repo']}#{p['number']}")['prs'].append(p)
    for s in sess:
        # A session counts for its own ticket and for every ticket it opened a PR for.
        pr_keys = [p['keys'][0] for n in s['prs'] if (p := by_number.get(n)) and p['keys']]
        keys = list(dict.fromkeys(s['keys'][:1] + pr_keys)) or ['session:' + s['id']]
        for key in keys:
            task(key)['sessions'].append(s)
    for key, issue in issues.items():
        if jira_state(issue['status']) == 'progress':
            task(key)

    agent_order = dict(working=0, waiting=1, done=2)
    out = []
    for key, t in tasks.items():
        jira_key = key if KEY.fullmatch(key) else None
        issue = issues.get(jira_key) if jira_key else None
        ss = sorted(t['sessions'], key=lambda s: (agent_order[s['status']], -s['last']))
        live = [p for p in t['prs'] if p['stage'] < 6]
        prs_ = sorted(live or t['prs'], key=lambda p: (p['stage'], p['stageState'] != 'fail'))
        lead = prs_[0] if prs_ else None
        open_prs = [p for p in t['prs'] if p['stage'] < 5]
        fresh_merge = [p for p in live if p['merged'] and NOW - p['merged'] < MERGED_SHOWN_HOURS * 3600]
        active = [x for x in ss if x['status'] == 'working' or
                  (x['status'] == 'waiting' and NOW - x['last'] < WAITING_SHOWN_HOURS * 3600)]
        if not (active or open_prs or fresh_merge or (issue and jira_state(issue['status']) == 'progress')):
            continue  # nothing to do or watch here
        session = ss[0] if ss else None
        if lead:
            stage, stage_state = lead['stage'], lead['stageState']
        else:
            stage, stage_state = 0, 'now' if session and session['status'] == 'working' else 'wait'
        if session and session['status'] == 'waiting':
            note = session['detail']
        elif len(t['prs']) > 1:
            note = f"{len(t['prs'])} PR-а"
        elif lead:
            note = f"{lead['repo']} #{lead['number']}"
        else:
            note = ''
        title = (session or {}).get('title') or (short_title(lead['title']) if lead else (issue or {}).get('title', key))
        out.append(dict(
            id=key, key=jira_key, title=title, note=note,
            agent=session['status'] if session else 'idle', lastActivity=session['last'] if session else None,
            url=(session or {}).get('url') or (lead or {}).get('url') or (issue or {}).get('url', ''),
            jira=None if not jira_key else dict(
                state=jira_state(issue['status']) if issue else ('unknown' if jira_error else 'todo'),
                label=issue['status'] if issue else ('няма достъп до Jira' if jira_error else 'не е намерен'),
                url=issue['url'] if issue else f'{JIRA}/browse/{jira_key}'),
            github=None if not lead else dict(state=lead['github'], url=lead['url'],
                                              label=f"{lead['repo']} #{lead['number']}", count=len(t['prs'])),
            stage=stage, stageState=stage_state,
        ))
    rank = dict(waiting=0, working=1, idle=2, done=3)
    out.sort(key=lambda t: (rank[t['agent']], t['stageState'] != 'fail', -(t['lastActivity'] or 0)))
    return out[:MAX_TASKS]


def main(local=False):
    """local: refresh the Claude sessions only and reuse the last GitHub/Jira/Slack answers (cheap, every 15 s)."""
    os.makedirs(OUT_DIR, exist_ok=True)
    remote = json.load(open(REMOTE_CACHE)) if os.path.exists(REMOTE_CACHE) else None
    if local and remote and NOW - remote['at'] < 300:
        sess = sessions()
        json.dump(_refs, open(REFS_CACHE, 'w'))
        write(dict(generatedAt=NOW, brand=CONFIG['brand'], tasks=build(sess, remote['pulls'], remote['issues'], 'jira' in remote['errors']),
                   slack=remote['slack'], stats=remote['stats'], errors=remote['errors']))
        return
    errors = {}

    def safe(name, f, fallback):
        try:
            return f.result(timeout=90)
        except Exception as e:  # one source down must not blank the others
            errors[name] = str(e).strip()[-200:] or type(e).__name__
            return fallback

    with cf.ThreadPoolExecutor(4) as pool:
        fs, fp, fc, fe = pool.submit(sessions), pool.submit(prs), pool.submit(pr_counts), pool.submit(e2e)
        sess = fs.result()
        pulls = safe('github', fp, [])
        counts = safe('prCounts', fc, None)
        e2e_state = safe('e2e', fe, None)
    keys = {k for x in sess + pulls for k in x['keys']}
    try:
        issues, closed = jira(keys)
    except Exception as e:
        issues, closed, errors['jira'] = {}, None, str(e)[-200:]
    json.dump(_refs, open(REFS_CACHE, 'w'))
    try:
        unread = slack()
    except Exception as e:
        unread, errors['slack'] = [], str(e)[-200:]
    stats = dict(prs=counts, jiraClosed=closed, e2e=e2e_state)
    json.dump(dict(at=NOW, pulls=pulls, issues=issues, slack=unread, stats=stats, errors=errors), open(REMOTE_CACHE, 'w'))
    write(dict(generatedAt=NOW, brand=CONFIG['brand'], tasks=build(sess, pulls, issues, 'jira' in errors), slack=unread,
               stats=stats, errors=errors))


def write(out):
    previous = json.load(open(OUT)) if os.path.exists(OUT) else {}
    strip = lambda d: json.dumps({k: v for k, v in d.items() if k != 'generatedAt'}, sort_keys=True, default=str)
    tmp = OUT + '.tmp'
    json.dump(out, open(tmp, 'w'), ensure_ascii=False, indent=1)
    os.replace(tmp, OUT)
    print('changed' if strip(previous) != strip(out) else 'same')


if __name__ == '__main__':
    main(local='--local' in sys.argv)
