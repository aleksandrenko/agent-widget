"""Collects the tasks for the Agent Widget panel: Claude sessions, my PRs and my Jira tickets,
grouped into one card per task by the Jira key (ABC-123) found in titles, branches and folders.

Settings (Jira site and projects, e2e workflow, brand) come from ~/.agent-widget/config.json; see
config.example.json. Without them those parts of the panel stay empty.
Writes ~/.agent-widget/tasks.json and prints `changed` or `same`.

    python3 collect.py           # everything
    python3 collect.py --local   # sessions and Slack only, last GitHub/Jira answers reused
    python3 collect.py --score   # the month's score into ~/.agent-widget/score.json (started in the background)
"""
import base64, concurrent.futures as cf, datetime as dt, glob, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

HOME = os.path.expanduser('~')
OUT_DIR = os.path.join(HOME, '.agent-widget')
OUT = os.path.join(OUT_DIR, 'tasks.json')
SESSIONS = os.path.join(HOME, 'Library/Application Support/Claude/claude-code-sessions')
TRANSCRIPTS = os.path.join(HOME, '.claude/projects')
CONFIG_FILE = os.environ.get('AGENT_WIDGET_CONFIG') or os.path.join(OUT_DIR, 'config.json')
DEFAULTS = dict(
    brand=dict(accent='#3DDC84'),
    jira=dict(site='', projects=[], activeStatuses=['In Progress', 'In Review']),
    e2e=dict(repo='', workflow='', titlePrefix=''),
    prod=dict(repo=''),
    mobile=dict(repo='', tagSuffix='-production', promoteWorkflow='', e2eWorkflow='', e2eBranch=''),
    prodComment='deployed to production',
    score=dict(target=230, org=''),
)


def load_config():
    config = json.load(open(CONFIG_FILE)) if os.path.exists(CONFIG_FILE) else {}
    return {k: {**v, **config.get(k, {})} if isinstance(v, dict) else config.get(k, v) for k, v in DEFAULTS.items()}


CONFIG = load_config()
JIRA = CONFIG['jira']['site'].rstrip('/')
LANG_BG = os.environ.get('THEWATCHER_LANG', 'bg') == 'bg'  # set by the app from the menu
# Modules turned off in the menu bar menu → Modules (e2e, portal, mobile, prs, jira, limit, calendar, slack): not fetched.
OFF = set(filter(None, os.environ.get('THEWATCHER_OFF', '').split(',')))


def tr(bg, en):
    return bg if LANG_BG else en


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
USAGE = os.path.join(OUT_DIR, 'usage.json')  # Claude plan limits, written by the birdwatcher-usage scheduled task
USAGE_STALE_HOURS = 3
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
                    questions[part.get('id')] = ((args.get('questions') or [{}])[0].get('question') or tr('Има въпрос към теб', 'A question for you'))
                elif name.endswith('wrap_up') and args.get('blocked'):
                    ask = args.get('ask') or args.get('recap') or tr('Чака отговор от теб', 'Waiting for your answer')
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
    count = lambda q: int(sh(['gh', 'api', '-X', 'GET', 'search/issues', '-f', f'q=is:pr author:@me {q}', '-q', '.total_count']))
    merged = lambda since: count(f'is:merged merged:>={since}')
    return dict(open=count('is:open archived:false'), week=merged(week), month=merged(month))


def e2e():
    """The configured e2e workflow (e.g. the full suite each release build goes through): last result,
    how many of the last 10 passed, and how many run now. None when no e2e workflow is configured."""
    e2e_cfg = CONFIG['e2e']
    if not (e2e_cfg['repo'] and e2e_cfg['workflow']):
        return None
    return workflow_runs(e2e_cfg['repo'], e2e_cfg['workflow'], prefix=e2e_cfg['titlePrefix'])


def workflow_runs(repo, workflow, prefix='', branch=''):
    """A workflow's last finished result, how many of the last 10 passed and how many run now; runs whose
    title starts with `prefix` and, with `branch`, only that branch's."""
    runs = json.loads(sh(['gh', 'run', 'list', '-R', repo, '--workflow', str(workflow), '-L', '60',
                          '--json', 'status,conclusion,displayTitle,createdAt,url'] + (['-b', branch] if branch else [])))
    full = [r for r in runs if r['displayTitle'].startswith(prefix)]
    running = [r for r in full if r['status'] != 'completed']
    done = [r for r in full if r['status'] == 'completed' and r['conclusion'] not in ('cancelled', 'skipped')]
    last = done[0] if done else None
    recent = done[:10]
    return dict(ok=bool(last) and last['conclusion'] == 'success', last=last and last['displayTitle'],
                lastAt=last and last['createdAt'], url=(running[0] if running else last or {}).get('url'),
                running=len(running), passed=sum(r['conclusion'] == 'success' for r in recent), recent=len(recent))


def prod():
    """When the configured repo last reached production, from its newest `prod-N` release. The deploy
    cuts the `prod-N+1` tag before it applies and publishes the release once done, so a tag without its
    release means one is going out now. None when no prod repo is configured."""
    repo = CONFIG['prod']['repo']
    if not repo:
        return None
    last = json.loads(sh(['gh', 'api', f'repos/{repo}/releases/latest']))
    match = re.fullmatch(r'(\D*)(\d+)', last['tag_name'])
    running = False
    if match:
        try:
            sh(['gh', 'api', f'repos/{repo}/git/ref/tags/{match.group(1)}{int(match.group(2)) + 1}'])
            running = True
        except RuntimeError:  # 404: no newer tag yet
            pass
    # Release notes list one "- feat(x): KEY: Title (#123)" line per PR; mine first, then the first others.
    listed = re.findall(r'^- (.+?) \(#(\d+)\)\s*$', last.get('body') or '', re.M)
    since = (dt.datetime.fromisoformat(last['published_at'].replace('Z', '+00:00')) - dt.timedelta(days=30)).date()
    mine = {int(n) for n in sh(['gh', 'api', '-X', 'GET', 'search/issues', '-f',
                               f'q=repo:{repo} is:pr is:merged author:@me merged:>={since}', '-f', 'per_page=100',
                               '-q', '.items[].number']).split()}
    prs = [dict(number=int(n), title=clip(short_title(t)), mine=int(n) in mine) for t, n in listed]
    shown = [p for p in prs if p['mine']] + [p for p in prs if not p['mine']][:12]
    return dict(tag=last['tag_name'], at=last['published_at'], url=last['html_url'], running=running,
                prs=shown, total=len(prs))


def mobile():
    """The mobile app's newest store release (the newest `<version><tagSuffix>` tag), the release candidate
    waiting after it, whether the promote workflow is shipping one now, and its e2e workflow's runs.
    None when no mobile repo is configured."""
    cfg = CONFIG['mobile']
    if not cfg['repo']:
        return None
    repo = cfg['repo']
    number = lambda t: [int(n) for n in re.findall(r'\d+', t)]
    tags = sorted((r['ref'][len('refs/tags/'):] for r in json.loads(sh(['gh', 'api', '--paginate', f'repos/{repo}/git/matching-refs/tags/v']))),
                  key=number)
    shipped = [t for t in tags if t.endswith(cfg['tagSuffix'])]
    if not shipped:
        return None
    tag = shipped[-1]
    ref = json.loads(sh(['gh', 'api', f'repos/{repo}/git/ref/tags/{tag}']))['object']
    if ref['type'] == 'tag':  # annotated: the tagger date is when it shipped
        at = json.loads(sh(['gh', 'api', f'repos/{repo}/git/tags/{ref["sha"]}']))['tagger']['date']
    else:
        at = json.loads(sh(['gh', 'api', f'repos/{repo}/commits/{ref["sha"]}']))['commit']['committer']['date']
    version = number(tag)  # its own candidates (v26.10.24-rc7) share the numbers and sort after it
    newer = [t for t in tags if not t.endswith(cfg['tagSuffix']) and number(t)[:len(version)] != version and number(t) > version]
    running = bool(cfg['promoteWorkflow']) and any(  # a run waiting for approval isn't going out yet
        r['status'] in ('in_progress', 'queued') for r in json.loads(sh(['gh', 'run', 'list', '-R', repo, '--workflow', str(cfg['promoteWorkflow']),
                                                           '-L', '5', '--json', 'status'])))
    e2e_state = workflow_runs(repo, cfg['e2eWorkflow'], branch=cfg['e2eBranch']) if cfg['e2eWorkflow'] else None
    return dict(tag=tag, at=at.replace('+00:00', 'Z'), url=f'https://github.com/{repo}/tags', running=running,
                candidate=newer[-1] if newer else None, e2e=e2e_state)


def slack():
    """Unread DMs + mentions from the number on Slack's Dock icon ("•" alone means only channel unreads)."""
    if 'slack' in OFF:
        return []
    out = subprocess.run(['lsappinfo', 'info', '-only', 'StatusLabel', 'Slack'], capture_output=True, text=True).stdout
    match = re.search(r'"label"="(\d+)"', out)
    if not match or int(match.group(1)) == 0:
        return []
    return [dict(id='slack', name='Slack', channel=None, text=tr('непрочетени лични съобщения и споменавания', 'unread direct messages and mentions'),
                 count=int(match.group(1)), url='slack://open')]


def usage():
    """Claude plan limits from the scheduled task's file; None when missing. Older than USAGE_STALE_HOURS it is
    still passed on, marked `stale`, so the panel can say the task stopped writing it instead of going blank."""
    if 'limit' in OFF or not os.path.exists(USAGE):
        return None
    data = json.load(open(USAGE))
    at = dt.datetime.fromisoformat(data['at'].replace('Z', '+00:00')).timestamp()
    if 'fiveHour' not in data:
        return None
    return dict(data, at=at, stale=NOW - at > USAGE_STALE_HOURS * 3600)


# The month's engineering KPI, the Normalized Score (REV-12239):
#   work points = 0.5 × item points + counted lines ÷ 450 + 0.5 × merged PRs, score = 10 × √(work points).
# GitHub takes a minute or more for a busy month (every PR with its files), so `collect.py --score` runs in the
# background every SCORE_EVERY_MINUTES and writes SCORE_FILE; the regular runs only read it.
SCORE_FILE = os.path.join(OUT_DIR, 'score.json')
SCORE_LOCK = os.path.join(OUT_DIR, 'score.lock')  # when the last background run started
SCORE_EVERY_MINUTES = 30
SCORE_QUERY = '''query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: 50, after: $after) {
  pageInfo { hasNextPage endCursor }
  nodes { ... on PullRequest { title url mergedAt headRefName additions deletions repository { name }
    files(first: 100) { nodes { path additions deletions } } } } } }'''
SCORE_KEY = re.compile(r'(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9]+-[0-9]+')
TEST_DIRS = {'__tests__', '__mocks__', '__snapshots__', 'test', 'tests', 'spec', 'specs', 'e2e', 'testdata', 'test-utils',
             'testutils', 'fixture', 'fixtures'}
TEST_DATA_DIRS = {'__snapshots__', '__mocks__', 'mocks', 'stubs', 'fixtures', 'fixture', 'testdata'}
TEST_DATA_EXTS = {'json', 'yaml', 'yml', 'csv', 'xml', 'html', 'txt', 'sql', 'eml'}
TEST_NAME = re.compile(r'\.(spec|test|e2e|e2e-spec)\.[^.]+$|^test_.*\.py$|_test\.(py|go)$|Tests?\.(java|kt|scala|groovy|cs)$|\.snap$')
LOCKFILE = re.compile(r'(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock|uv\.lock|'
                      r'Gemfile\.lock|composer\.lock|Cargo\.lock|go\.sum|packages\.lock\.json)$')


def excluded(repo, path):
    """A file the score leaves out: lockfiles, test data inside test paths, docs folders outside test paths."""
    *folders, name = path.split('/')
    low = [f.lower() for f in folders]
    ext = name.rsplit('.', 1)[-1].lower() if '.' in name else ''
    test_path = (any(f in TEST_DIRS for f in low) or any(re.fullmatch(r'[a-z0-9_.]+-tests?', f, re.I) for f in folders)
                 or TEST_NAME.search(name) or re.search(r'(^|[-_.])(e2e|tests?)($|[-_.])', repo, re.I))
    test_file = repo != 'e2e-tests' and bool(test_path)
    return bool(LOCKFILE.search(path)
                or (test_file and (any(f in TEST_DATA_DIRS for f in low) or name.endswith('.snap') or ext in TEST_DATA_EXTS))
                or (not test_file and any(f in ('doc', 'docs', 'openspec') for f in low)))


def item_points(lines):
    """The PR's size band: XXS 0.5, XS 1, S 2, M 3, L 5, XL 8."""
    return next((points for limit, points in ((15, 0.5), (30, 1), (150, 2), (600, 3), (2000, 5)) if lines < limit), 8)


def score_pr(n, done):
    """One PR for the score. Its item is the first Jira key in its title or branch, a key Jira confirmed as done
    first (words such as utf-8 look like keys). `done` is None when Jira did not answer: every named item counts."""
    repo = n['repository']['name']
    files = [f for f in ((n.get('files') or {}).get('nodes') or []) if f]
    lines = max(n['additions'] + n['deletions'] - sum(f['additions'] + f['deletions'] for f in files if excluded(repo, f['path'])), 0)
    keys = [k.upper() for k in SCORE_KEY.findall(f"{n['title']} {n['headRefName']}")]
    key = next((k for k in keys if done and k in done), keys[0] if keys else None)
    return dict(repo=repo, url=n['url'], lines=lines, points=item_points(lines), merged=n.get('mergedAt') or 'open',
                norm=' '.join(n['title'].lower().split()), key=key, item=key is not None and (done is None or key in done))


def counted(prs):
    """The PRs that count for lines and the PR count: no automatic titles, and one PR for a title merged in 3+ repos."""
    groups = {}
    for p in prs:
        if not re.match(r'(auto update triggered|chore\(dependencies\):)', p['norm']):
            groups.setdefault(p['norm'], []).append(p)
    return [p for g in groups.values() for p in ([min(g, key=lambda p: (p['merged'], p['url']))] if len({p['repo'] for p in g}) >= 3 else g)]


def bonuses(prs):
    """A done item whose PRs span several repos gets one item point per extra repo, at most 5."""
    repos = {}
    for p in prs:
        if p['item']:
            repos.setdefault(p['key'], set()).add(p['repo'])
    return [min(5, len(r) - 1) for r in repos.values() if len(r) > 1]


def work_points(prs):
    c = counted(prs)
    return (0.5 * (sum(p['points'] for p in prs if p['item']) + sum(bonuses(prs)))
            + sum(min(p['lines'], 2000) for p in c) / 450 + 0.5 * len(c))


def search_all(q):
    """Every PR of a GitHub search, 50 a page; each page is retried on its own (heavy pages get an occasional 502)."""
    nodes, after = [], None
    while True:
        args = ['gh', 'api', 'graphql', '-f', 'query=' + SCORE_QUERY, '-f', 'q=' + q] + (['-f', 'after=' + after] if after else [])
        for attempt in range(3):
            try:
                page = json.loads(sh(args, timeout=60))['data']['search']
                break
            except (RuntimeError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
                if attempt == 2:
                    raise
                time.sleep(2)
        nodes += [n for n in page['nodes'] if n]
        if not page['pageInfo']['hasNextPage']:
            return nodes
        after = page['pageInfo']['endCursor']


def done_keys(keys):
    """The keys among `keys` that are my items in Done, QA or Resolved; None when Jira did not answer."""
    if not keys:
        return set()
    email, token = keychain('jira_email'), keychain('jira_api_token')
    if not (JIRA and email and token):
        return None
    headers = {'Authorization': 'Basic ' + base64.b64encode(f'{email}:{token}'.encode()).decode(),
               'Accept': 'application/json', 'Content-Type': 'application/json'}
    post = lambda path, body: json.load(urllib.request.urlopen(urllib.request.Request(
        JIRA + path, data=json.dumps(body).encode(), method='POST', headers=headers), timeout=30))
    keys = sorted(keys)
    try:
        for _ in range(4):  # Jira refuses the whole search for a key that does not exist: drop the ones it names
            try:
                found, page = set(), None
                while True:
                    data = post('/rest/api/3/search/jql', dict(
                        jql=f'key in ({",".join(keys)}) AND assignee = currentUser() AND status IN (Done, QA, Resolved)',
                        fields=['status'], maxResults=100, **({'nextPageToken': page} if page else {})))
                    found |= {i['key'] for i in data.get('issues', [])}
                    page = data.get('nextPageToken')
                    if not page:
                        break
                break
            except urllib.error.HTTPError as e:
                bad = set(re.findall(r"'([A-Za-z][A-Za-z0-9]+-\d+)'", e.read().decode(errors='replace'))) if e.code == 400 else set()
                keys = [k for k in keys if k not in bad]
                if not bad or not keys:
                    return None if bad == set() else set()
        else:
            return None
        if not found:  # a wrong token is answered as an anonymous user: no issues, no error
            urllib.request.urlopen(urllib.request.Request(JIRA + '/rest/api/3/myself', headers=headers), timeout=20)
        return found
    except Exception:
        return None


def score_month():
    """Fetches the month and writes SCORE_FILE; a failure keeps the last numbers and adds the error."""
    cfg = CONFIG['score']
    org = f" org:{cfg['org']}" if cfg['org'] else ''
    today = dt.datetime.now(dt.timezone.utc).date()  # the dashboard buckets a PR by the UTC month of its merge
    start = today.replace(day=1)
    last_end = start - dt.timedelta(days=1)
    last_start = last_end.replace(day=1)
    try:
        merged_nodes = search_all(f'is:pr is:merged author:@me{org} merged:>={start}')
        open_nodes = search_all(f'is:pr is:open archived:false author:@me{org}')
        # Last month's PRs do not change: fetched once and kept. Their items can still reach Done, so Jira is asked again.
        last_file = os.path.join(OUT_DIR, f'score-last-{last_start:%Y-%m}.json')
        try:
            last_nodes = json.load(open(last_file))
        except (OSError, ValueError):
            try:
                last_nodes = search_all(f'is:pr is:merged author:@me{org} merged:{last_start}..{last_end}')
                json.dump(last_nodes, open(last_file, 'w'))
                for old in glob.glob(os.path.join(OUT_DIR, 'score-last-*.json')):
                    if old != last_file:
                        os.remove(old)
            except Exception:
                last_nodes = None
        done = done_keys({k.upper() for n in merged_nodes + open_nodes + (last_nodes or [])
                          for k in SCORE_KEY.findall(f"{n['title']} {n['headRefName']}")})
        merged = [score_pr(n, done) for n in merged_nodes]
        as_done = lambda prs: [dict(p, item=p['key'] is not None) for p in prs]
        opened = as_done([score_pr(n, done) for n in open_nodes])
        work = work_points(merged)
        weekdays = [d for d in (start + dt.timedelta(days=i) for i in range(31)) if d.month == start.month and d.weekday() < 5]
        days, elapsed = len(weekdays), len([d for d in weekdays if d <= today])
        c = counted(merged)
        bonus = 0.5 * sum(bonuses(merged))
        lost = sorted([
            dict(id='jira', count=len([p for p in merged if p['key'] and not p['item']]), points=work_points(as_done(merged)) - work),
            dict(id='cap', count=len([p for p in c if p['lines'] > 2000]), points=sum((p['lines'] - 2000) / 450 for p in c if p['lines'] > 2000)),
            dict(id='nokey', count=len([p for p in merged if not p['key']]), points=0.5 * sum(p['points'] for p in merged if not p['key'])),
        ], key=lambda x: -x['points'])
        last_work = work_points([score_pr(n, done) for n in last_nodes]) if last_nodes is not None else None
        out = dict(at=time.time(), month=f'{start:%Y-%m}', target=cfg['target'], score=10 * work ** 0.5, work=work,
                   forecast=10 * (work * days / elapsed) ** 0.5 if elapsed else 10 * work ** 0.5, days=days, elapsed=elapsed,
                   merged=dict(count=len(merged), points=work - bonus), bonus=dict(count=len(bonuses(merged)), points=bonus),
                   lost=lost, open=dict(count=len(opened), points=work_points(merged + opened) - work), jira=done is not None,
                   last=None if last_work is None else dict(month=f'{last_start:%Y-%m}', score=10 * last_work ** 0.5, work=last_work))
    except Exception as e:
        out = json.load(open(SCORE_FILE)) if os.path.exists(SCORE_FILE) else None
        if out is None:
            raise
        out['error'] = str(e).strip()[-200:] or type(e).__name__
    tmp = SCORE_FILE + '.tmp'
    json.dump(out, open(tmp, 'w'))
    os.replace(tmp, SCORE_FILE)


def score():
    """The month's score from SCORE_FILE, and a background run when it is older than SCORE_EVERY_MINUTES (at most one
    every 10 minutes, so a failing one does not run every minute). None until the month's first run is done."""
    if 'score' in OFF:
        return None
    data = json.load(open(SCORE_FILE)) if os.path.exists(SCORE_FILE) else None
    month = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m')
    fresh = data and data.get('month') == month and not data.get('error') and NOW - data['at'] < SCORE_EVERY_MINUTES * 60
    if not fresh and not (os.path.exists(SCORE_LOCK) and NOW - os.path.getmtime(SCORE_LOCK) < 600):
        open(SCORE_LOCK, 'w').close()
        subprocess.Popen([sys.executable, os.path.abspath(__file__), '--score'], start_new_session=True, env=os.environ,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(os.path.join(OUT_DIR, 'collect.log'), 'a'))
    return data if data and data.get('month') == month else None


def keychain(service):
    try:
        return sh(['security', 'find-generic-password', '-a', os.environ.get('USER', ''), '-s', service, '-w']).strip()
    except RuntimeError:
        return ''


def jira(extra_keys, counts=True):
    """The tickets for the task rows, and (`counts`) my open / done-this-month counts for the footer."""
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
    if not counts:
        return issues, None
    week, month = week_month()
    def count(jql):  # Jira counts on its side: no 100-issue page cap
        body = json.dumps(dict(jql=jql)).encode()
        request = urllib.request.Request(JIRA + '/rest/api/3/search/approximate-count', data=body, method='POST',
                                         headers={**headers, 'Content-Type': 'application/json'})
        return json.load(urllib.request.urlopen(request, timeout=20))['count']
    # Done means Jira's Done category: a ticket on staging still counts as open.
    closed = lambda since: count(f'assignee = currentUser() AND statusCategory = Done AND statusCategoryChangedDate >= "{since}"')
    still_open = count('assignee = currentUser() AND statusCategory != Done')
    mine = get('/rest/api/3/search/jql?' + urllib.parse.urlencode(dict(
        jql='assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC', fields='summary,status', maxResults=15)))
    open_list = [dict(key=i['key'], title=clip(i['fields']['summary'], 60), status=i['fields']['status']['name'])
                 for i in mine.get('issues', [])]
    return issues, dict(open=still_open, week=closed(week), month=closed(month), openList=open_list)


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


def clip(text, size=70):
    """One tooltip line: long titles end in an ellipsis."""
    return text if len(text) <= size else text[:size - 1].rstrip() + '…'


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
            note = f"{len(t['prs'])} " + tr('PR-а', 'PRs')
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
                label=issue['status'] if issue else (tr('няма достъп до Jira', 'no access to Jira') if jira_error else tr('не е намерен', 'not found')),
                url=issue['url'] if issue else f'{JIRA}/browse/{jira_key}'),
            github=None if not lead else dict(state=lead['github'], url=lead['url'],
                                              label=f"{lead['repo']} #{lead['number']}", count=len(t['prs'])),
            stage=stage, stageState=stage_state,
        ))
    rank = dict(waiting=0, working=1, idle=2, done=3)
    out.sort(key=lambda t: (rank[t['agent']], t['stageState'] != 'fail', -(t['lastActivity'] or 0)))
    return out[:MAX_TASKS]


def main(local=False):
    """local: refresh the Claude sessions and Slack only and reuse the last GitHub/Jira answers (cheap, every 15 s)."""
    os.makedirs(OUT_DIR, exist_ok=True)
    remote = json.load(open(REMOTE_CACHE)) if os.path.exists(REMOTE_CACHE) else None
    if local and remote and NOW - remote['at'] < 300:
        sess = sessions()
        json.dump(_refs, open(REFS_CACHE, 'w'))
        try:
            unread = slack()  # local and cheap: read it every time, so a read message leaves the panel within 15 s
        except Exception:
            unread = remote['slack']
        write(dict(generatedAt=NOW, brand=CONFIG['brand'], tasks=build(sess, remote['pulls'], remote['issues'], 'jira' in remote['errors']),
                   slack=unread, stats=dict(remote['stats'], ai=usage(), score=score()), errors=remote['errors']))
        return
    errors = {}

    def safe(name, f, fallback):
        try:
            return f.result(timeout=90)
        except Exception as e:  # one source down must not blank the others
            errors[name] = str(e).strip()[-200:] or type(e).__name__
            return fallback

    on = lambda module, f: (lambda: None) if module in OFF else f
    with cf.ThreadPoolExecutor(6) as pool:
        fs, fp, fc, fe, fd, fm = (pool.submit(sessions), pool.submit(prs), pool.submit(on('prs', pr_counts)), pool.submit(on('e2e', e2e)),
                                  pool.submit(on('portal', prod)), pool.submit(on('mobile', mobile)))
        sess = fs.result()
        pulls = safe('github', fp, [])
        counts = safe('prCounts', fc, None)
        if counts is not None:  # the open ones are already in pulls, for the task rows
            counts['openList'] = [dict(repo=p['repo'], number=p['number'], title=clip(short_title(p['title'])))
                                  for p in pulls if p['merged'] is None]
        e2e_state = safe('e2e', fe, None)
        prod_state = safe('prod', fd, None)
        mobile_state = safe('mobile', fm, None)
    keys = {k for x in sess + pulls for k in x['keys']}
    try:
        issues, closed = jira(keys, counts='jira' not in OFF)
    except Exception as e:
        issues, closed, errors['jira'] = {}, None, str(e)[-200:]
    json.dump(_refs, open(REFS_CACHE, 'w'))
    try:
        unread = slack()
    except Exception as e:
        unread, errors['slack'] = [], str(e)[-200:]
    try:
        month_score = score()
    except Exception as e:
        month_score, errors['score'] = None, str(e)[-200:]
    if month_score and month_score.get('error'):
        errors['score'] = month_score['error']
    stats = dict(prs=counts, jira=closed, e2e=e2e_state, prod=prod_state, mobile=mobile_state, ai=usage(), score=month_score)
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
    if '--score' in sys.argv:
        score_month()
    else:
        main(local='--local' in sys.argv)
