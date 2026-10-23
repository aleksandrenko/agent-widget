"""Test cases for the collector's pure logic: Jira keys, PR stages, Jira states and task grouping.

    python3 -m unittest collector/test_collect.py
"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(__file__))
os.environ['AGENT_WIDGET_CONFIG'] = '/nonexistent'  # the defaults, not your own config.json
import collect  # noqa: E402

NOW = collect.NOW


def pr(state='OPEN', draft=False, decision=None, mergeable='MERGEABLE', ci='SUCCESS', approvals=0, comments=()):
    return dict(state=state, isDraft=draft, reviewDecision=decision, mergeable=mergeable,
                commits=dict(nodes=[dict(commit=dict(statusCheckRollup=dict(state=ci) if ci else None))]),
                reviews=dict(nodes=[dict(state='APPROVED')] * approvals),
                comments=dict(nodes=[dict(body=b) for b in comments]))


def session(id, status, keys=(), hours_ago=0.1, detail=''):
    return dict(id=id, title=f'Session {id}', status=status, detail=detail, last=NOW - hours_ago * 3600,
                url=f'claude://code/continue?session={id}', keys=list(keys), prs=[])


def pull(number, keys, stage, state='now', github='review', merged_hours_ago=None):
    merged = NOW - merged_hours_ago * 3600 if merged_hours_ago is not None else None
    return dict(number=number, repo='web', url=f'https://github.com/x/web/pull/{number}', title=f'feat(web): {keys[0] if keys else ""}: Do it',
                merged=merged, stage=stage, stageState=state, github=github, keys=list(keys))


class JiraKeys(unittest.TestCase):
    def test_finds_keys_in_titles_branches_and_folders(self):
        self.assertEqual(collect.keys_in('feat(web): WEB-1201: Show cards', 'API-1188-esm', None), ['WEB-1201', 'API-1188'])

    def test_ignores_look_alikes(self):
        self.assertEqual(collect.keys_in('UTF-8 and ISO-8601 and HTTP-2'), [])


class PrStages(unittest.TestCase):
    def test_draft_is_pushed(self):
        self.assertEqual(collect.pr_stage(pr(draft=True)), (1, 'now', 'draft'))

    def test_waiting_for_ai_review(self):
        self.assertEqual(collect.pr_stage(pr()), (2, 'now', 'review'))

    def test_ai_review_asked_for_changes(self):
        self.assertEqual(collect.pr_stage(pr(decision='CHANGES_REQUESTED')), (2, 'fail', 'changes'))

    def test_approved_and_ci_running(self):
        self.assertEqual(collect.pr_stage(pr(decision='APPROVED', ci='PENDING')), (3, 'now', 'ci'))

    def test_approved_and_ci_red(self):
        self.assertEqual(collect.pr_stage(pr(decision='APPROVED', ci='FAILURE')), (3, 'fail', 'fail'))

    def test_conflict_counts_as_red(self):
        self.assertEqual(collect.pr_stage(pr(approvals=1, mergeable='CONFLICTING')), (3, 'fail', 'fail'))

    def test_approved_and_green_waits_for_merge(self):
        self.assertEqual(collect.pr_stage(pr(decision='APPROVED')), (4, 'wait', 'ready'))

    def test_merged_is_on_staging(self):
        self.assertEqual(collect.pr_stage(pr(state='MERGED')), (5, 'wait', 'merged'))

    def test_release_comment_means_prod(self):
        merged = pr(state='MERGED', comments=['🚀 This PR has been deployed to production in release prod-1234'])
        self.assertEqual(collect.pr_stage(merged), (6, 'wait', 'prod'))


class JiraStates(unittest.TestCase):
    def test_maps_board_columns(self):
        cases = {'To Do': 'todo', 'BACKLOG': 'todo', 'In Progress': 'progress', 'In Review': 'review',
                 'On staging': 'staging', 'Done': 'done', 'Blocked': 'blocked'}
        for status, state in cases.items():
            with self.subTest(status=status):
                self.assertEqual(collect.jira_state(status), state)


class ShortTitles(unittest.TestCase):
    def test_drops_the_conventional_commit_prefix_and_key(self):
        self.assertEqual(collect.short_title('perf(ui): WEB-4577: Draw each icon from its own file'), 'Draw each icon from its own file')


class Grouping(unittest.TestCase):
    def test_session_and_prs_with_one_key_are_one_task(self):
        tasks = collect.build([session('a', 'working', ['WEB-1201'])],
                              [pull(1, ['WEB-1201'], 2), pull(2, ['WEB-1201'], 4, 'wait', 'ready')], {}, False)
        self.assertEqual(len(tasks), 1)
        self.assertEqual((tasks[0]['agent'], tasks[0]['stage'], tasks[0]['github']['count']), ('working', 2, 2))

    def test_session_shows_on_every_ticket_it_opened_a_pr_for(self):
        worker = session('a', 'working', ['WEB-1201'])
        worker['prs'] = [7]
        tasks = collect.build([worker], [pull(6, ['WEB-1201'], 2), pull(7, ['WEB-1202'], 5, 'wait', 'merged', merged_hours_ago=1)], {}, False)
        self.assertEqual(sorted((t['key'], t['agent']) for t in tasks), [('WEB-1201', 'working'), ('WEB-1202', 'working')])

    def test_waiting_comes_before_working(self):
        tasks = collect.build([session('a', 'working', ['WEB-1201']), session('b', 'waiting', ['WEB-1202'])], [], {}, False)
        self.assertEqual([t['agent'] for t in tasks], ['waiting', 'working'])

    def test_old_waiting_session_with_nothing_open_is_hidden(self):
        self.assertEqual(collect.build([session('a', 'waiting', ['WEB-1201'], hours_ago=30)], [], {}, False), [])

    def test_finished_session_without_open_work_is_hidden(self):
        self.assertEqual(collect.build([session('a', 'done', ['WEB-1201'])], [], {}, False), [])

    def test_open_pr_without_agent_shows_as_idle(self):
        tasks = collect.build([], [pull(1, ['WEB-1201'], 3, 'now', 'ci')], {}, False)
        self.assertEqual((tasks[0]['agent'], tasks[0]['github']['state']), ('idle', 'ci'))

    def test_merged_pr_shows_for_a_day(self):
        fresh = collect.build([], [pull(1, ['WEB-1201'], 5, 'wait', 'merged', merged_hours_ago=2)], {}, False)
        stale = collect.build([], [pull(1, ['WEB-1201'], 5, 'wait', 'merged', merged_hours_ago=30)], {}, False)
        self.assertEqual((len(fresh), len(stale)), (1, 0))

    def test_jira_without_access_is_marked_unknown(self):
        tasks = collect.build([session('a', 'working', ['WEB-1201'])], [], {}, True)
        self.assertEqual(tasks[0]['jira']['state'], 'unknown')

    def test_at_most_eight_tasks(self):
        sessions = [session(str(i), 'working', [f'WEB-{1300 + i}']) for i in range(12)]
        self.assertEqual(len(collect.build(sessions, [], {}, False)), collect.MAX_TASKS)


if __name__ == '__main__':
    unittest.main()
