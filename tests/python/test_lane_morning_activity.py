"""Offline, pure-function tests for the morning sweep."""
import importlib.util
import json
import pathlib
import tempfile
import unittest
from typing import Any
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("activity_morning", pathlib.Path(__file__).resolve().parents[2] / "ai/marketplace/plugins/my/skills/lane-coordinator/scripts/morning.py")
assert spec is not None and spec.loader is not None
morning: Any = importlib.util.module_from_spec(spec)
spec.loader.exec_module(morning)
# Synthetic project settings for pure activity tests; no private defaults.
morning.REPOS = ("example/core", "example/suite", "example/sessions", "example/runtime", "upstream/engine", "upstream/runtime")
morning.OWN_ONLY = {"upstream/engine"}
morning.OURS = {"example/core", "example/sessions"}
morning.ALIASES = {"core": "example/core", "suite": "example/suite", "sessions": "example/sessions", "runtime": "example/runtime", "config": "example/config", "engine": "upstream/engine", "team": "upstream/team", "canvas": "example/canvas"}
morning.WATCH = (("upstream/engine", 2595), ("upstream/runtime", 4))
morning.NOTIFICATIONS = morning.INTERNAL_TRACKER = True
morning.INTERNAL_SOURCE = {"host": "git.example.test", "repo": "example/tracker"}



class StateParsingTests(unittest.TestCase):
    def test_pr_references(self):
        for text, expected in [
            ("core#702 runtime#70 sessions#216 engine#2957 team#2275 suite#62 canvas#9",
             [("example/core", 702), ("example/runtime", 70),
              ("example/sessions", 216), ("upstream/engine", 2957),
              ("upstream/team", 2275), ("example/suite", 62), ("example/canvas", 9)]),
            ("https://github.com/example/project/pull/12", [("example/project", 12)]),
            ("mystery#8", [(None, 8)]),
            ("config#59", [("example/config", 59)]),
            ("example-user/runtime#9 example-org/canvas#4",
             [("example-user/runtime", 9), ("example-org/canvas", 4)]),
            ("core#687/#688; bare #449 is not qualified", [("example/core", 687),
                                                         ("example/core", 688)]),
        ]:
            with self.subTest(text=text):
                refs = morning.parse_pr_refs(text)
                self.assertEqual([(r["repo"], r["number"]) for r in refs], expected)

    def test_issue_references_ignore_code_and_keep_url_repository(self):
        cases = [
            ("Closes #12; Refs #13; Part of #14; see #15",
             [("example/project", 12, "Closes"), ("example/project", 13, "Refs"),
              ("example/project", 14, "Refs"), ("example/project", 15, "mention")]),
            ("Fixes https://github.com/other/repo/issues/9 and #10",
             [("other/repo", 9, "Closes"), ("example/project", 10, "mention")]),
            ("`#12` ``Refs #13`` `https://github.com/other/repo/issues/9` #14",
             [("example/project", 14, "mention")]),
            ("`foo ``` #12 bar` Refs #13", [("example/project", 13, "Refs")]),
            ("Refs [#9](https://github.com/other/repo/issues/9) "
             "[#12](https://github.com/third/repo/pull/12)", [("other/repo", 9, "Refs")]),
            ('<a href="https://redirect.github.com/actions/setup-python/issues/1370">#1370</a>',
             [("actions/setup-python", 1370, "mention")]),
            ("https://github.com/other/repo/pull/9 word#10 ##11 # heading", []),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(morning.parse_issue_refs(text, "example/project"), expected)

    def test_waiting_lines(self):
        for text, expected in [("open, awaiting review", True), ("Parked: runtime#36", True),
                               ("next: merge core#7", True), ("core#7 merged yesterday", False),
                               ("plain historical note", False)]:
            with self.subTest(text=text):
                self.assertEqual(morning.reads_as_waiting(text), expected)

    def test_completed_reference_is_not_a_waiting_claim(self):
        for text, number, expected in [
            ("PR1 core#31, PR2 core#34 and PR3 core#38 MERGED 10-23. Next: PR4", 31, False),
            ("PR1 core#31, PR2 core#34 and PR3 core#38 MERGED 10-23. Next: PR4", 34, False),
            ("PR1 core#31, PR2 core#34 and PR3 core#38 MERGED 10-23. Next: PR4", 38, False),
            ("| W23 | PR1 core#31, PR2 #34, PR3 #38 merged 10-23; PR4 next | lane: PR4 |", 31, False),
            ("core#7 closed; next: follow-up", 7, False),
            ("Merged core#7; next: follow-up", 7, False),
            ("core#7 merged; core#8 open, awaiting review", 8, True),
            ("core#7 merged, core#8 open, awaiting review", 8, True),
            ("core#7 open, awaiting review; core#8 merged", 7, True),
        ]:
            with self.subTest(text=text, number=number):
                ref = next(r for r in morning.parse_pr_refs(text) if r["number"] == number)
                self.assertEqual(morning.reads_as_waiting(text, ref), expected)

    def test_failed_queries_are_named_individually(self):
        text = morning.failure_section([("repos/example/a/issues/1", "offline"),
                                        ("repos/example/b/issues/2", "offline")])
        self.assertEqual(text.splitlines(), ["## Failed queries",
                         "- `repos/example/a/issues/1`: offline",
                         "- `repos/example/b/issues/2`: offline"])
        self.assertEqual(morning.failure_section([]), "")

    def test_closed_owners_not_historical_mentions(self):
        archive = "# Closed lanes\n| W12 | done |\n- W13 CLOSED\n"
        state = ("## Open lanes\n| W20 | ready | W12: fix CI | report |\n"
                 "- W13 owns the retry\n- W21 saw W12's old report\n"
                 "**Completed lanes:** CLOSED-2026-10.md. W22 still needs review.\n"
                 "**Stopped:** W14 (superseded).\n- owner: W14\n"
                 "## Closed lanes\n| W12 | owner: W13 |\n")
        self.assertEqual([item[1] for item in morning.closed_lane_owners(state, archive)],
                         ["W12", "W13", "W14"])
        state_only = ("## Closed lanes\n| W99 | done |\n## Open lanes\n"
                      "**Stopped:** W98\n| W20 | ready | W99: resume | report |\n- owner: W98\n")
        self.assertEqual([item[1] for item in morning.closed_lane_owners(state_only, "")],
                         ["W99", "W98"])

    def test_word_budgets(self):
        docs = {"AGENTS": "word " * 901, "COORDINATION": "word " * 1500,
                "PEOPLE": "word\n" * 701, "STATE": "word " * 1601}
        rows = morning.budget_counts(docs, {"W20": "word " * 801, "W21": "word " * 800})
        self.assertEqual(rows, [("AGENTS", 901, 900, True), ("COORDINATION", 1500, 1500, False),
                                ("PEOPLE", 701, 700, True), ("STATE", 1601, 1600, True),
                                ("W20", 801, 800, True), ("W21", 800, 800, False)])

    def test_stamp_minute_is_included(self):
        for timestamp, expected in [("2026-10-23T13:30:40Z", True),
                                    ("2026-10-23T13:29:59Z", False),
                                    ("2026-10-23T09:30:00-04:00", True)]:
            self.assertEqual(morning.since_stamp(timestamp, "2026-10-23T13:30Z"), expected)
        self.assertTrue(morning.since_stamp("2026-10-23T00:00:00Z", "2026-10-23"))

    def test_row_date_is_compared_with_header(self):
        self.assertEqual(morning.state_dates("Last updated: 2026-10-23\n| W9 | next 10-26 |"),
                         ("2026-10-23", "2026-10-26"))
        self.assertEqual(morning.state_dates("Last updated: 2026-10-23\n| W9 | 2026-10-22 |"),
                         ("2026-10-23", "2026-10-22"))

    def test_sha_after_status_does_not_belong_to_next_pr(self):
        for text, expected in [("squad#2275 open @e8034ae7", "e8034ae7"),
                               ("core#8 green; core#9 @abcdef12", None),
                               ("runtime#70 @a79b07c2; review", "a79b07c2")]:
            self.assertEqual(morning.written_head(morning.parse_pr_refs(text)[0]), expected)

    def test_folder_name_is_not_a_lane_prefix(self):
        self.assertFalse(morning.folder_named("reports: w502-work/REPORT.md", "w50"))
        self.assertTrue(morning.folder_named("reports: `w502-work/REPORT.md`", "w502-work"))
        self.assertTrue(morning.folder_named("see w502-work.", "w502-work"))

    def test_bot_and_check_classification(self):
        for login in ["dependabot[bot]", "coderabbitai", "copilot-pull-request-reviewer", "Copilot"]:
            self.assertFalse(morning.is_human(login))
        self.assertTrue(morning.is_human("merger-user"))
        self.assertFalse(morning.is_human("chatgpt-codex-connector", "Bot"))
        self.assertEqual(morning.checks_summary([{"conclusion": "FAILURE"}]), "red")
        self.assertEqual(morning.checks_summary([{"state": "PENDING"}]), "running")
        self.assertEqual(morning.checks_summary([]), "none")


SINCE = "2026-10-25T12:50:00Z"
NOW = "2026-10-26T07:13:09Z"


def sweep_item(number, login="example-user", pr=False):
    item = dict(repository_url="https://api.github.com/repos/example/sessions",
                number=number, html_url=f"https://github.com/example/sessions/issues/{number}",
                title=f"Item {number}", user=dict(login=login, type="User"), created_at=NOW)
    if pr:
        item["pull_request"] = {}
    return item


def comment(login, kind="User", timestamp=NOW):
    return dict(user=dict(login=login, type=kind), created_at=timestamp,
                updated_at=timestamp, submitted_at=timestamp, state="COMMENTED",
                html_url=f"https://github.com/comment/{login}")


class SweepClient(morning.GitHub):
    def __init__(self, items=(), comments=(), reviews=(), inline=(), opened=(), merged=(), fail=None):
        super().__init__()
        self.items, self.comments, self.reviews, self.inline = items, comments, reviews, inline
        self.opened, self.merged, self.failure = opened, merged, fail
        self.calls = []

    def search(self, query, host=None):
        if "involves:" in query:
            return self.items
        if "is:issue created:" in query:
            return self.opened
        if "is:merged" in query:
            return self.merged if "author:example-user" not in query else []
        return []

    def pages(self, endpoint, host=None, **params):
        key = (host, endpoint, tuple(sorted(params.items())))
        if key not in self.page_cache:
            pages = self.gh("api", endpoint, host=host)
            self.page_cache[key] = [row for page in pages for row in page] if pages is not None else None
        return self.page_cache[key]

    def gh(self, *args, host=None, budget_optional=False):
        self.calls.append(args)
        endpoint = args[args.index("GET") + 1] if "GET" in args else args[-1]
        if self.failure and self.failure in endpoint:
            self.fail(endpoint, "offline")
            return None
        if endpoint in {"repos/upstream/engine/issues/2595", "repos/upstream/runtime/issues/4"}:
            return dict(title="Watched item", state="open", updated_at=NOW)
        if endpoint.endswith("/reviews"):
            return [self.reviews]
        if "/pulls/" in endpoint and endpoint.endswith("/comments"):
            return [self.inline]
        if endpoint.endswith("/comments"):
            return [self.comments]
        if "/pulls/" in endpoint:
            return dict(merged_at=NOW, merged_by=dict(login="merger-user", type="User"))
        return [[]]


class SweepTests(unittest.TestCase):
    def filtered(self, client):
        text = morning.sweep(client, SINCE, "example-user")
        return text.split("## New comments or reviews on your PRs/issues\n")[1].split("\n## ")[0]

    def test_merged_references_list_only_open_issues_and_report_unknown(self):
        class IssueClient(SweepClient):
            def gh(self, *args, host=None, budget_optional=False):
                endpoint = args[-1]
                if endpoint.endswith("/pulls/216"):
                    return dict(merged_at=NOW, merged_by=dict(login="merger-user", type="User"),
                                title="Refs #1", body="Closes #2; #3; #4; #5; Refs #1")
                if "/issues/" in endpoint and not endpoint.endswith("/comments"):
                    number = int(endpoint.rsplit("/", 1)[1])
                    if number == 5:
                        self.fail(endpoint, "offline")
                        return None
                    return dict(state="closed" if number == 2 else "open", title=f"Issue {number}",
                                updated_at=NOW, **({"pull_request": {}} if number == 3 else {}))
                return super().gh(*args, host=host)

        text = morning.sweep(IssueClient(merged=[sweep_item(216, pr=True)]), SINCE, "example-user")
        section = text.split("## Open issues referenced by PRs merged since the last run\n")[1].split("\n## ")[0]
        self.assertIn('sessions#1 Issue 1 — PR #216 "Refs"', section)
        self.assertEqual(section.count("sessions#1"), 1)
        self.assertIn('sessions#4 Issue 4 — PR #216 mention', section)
        self.assertIn("sessions#5", section)
        self.assertIn("unknown", section)
        self.assertNotIn("Issue 2", section)
        self.assertNotIn("Issue 3", section)
        self.assertIn("offline", text)

    def test_watch_states_and_engine_runtime_wide_queries(self):
        class WatchClient(SweepClient):
            def search(self, query, host=None):
                self.queries.append(query)
                return []

            def gh(self, *args, host=None, budget_optional=False):
                if args[-1] == "repos/upstream/engine/issues/2595":
                    self.calls.append(args)
                    if self.watched is None:
                        self.fail(args[-1], "offline")
                    return self.watched
                return super().gh(*args, host=host)

        for state, merged, expected in [("open", None, "open, updated " + NOW),
                                        ("closed", None, "closed " + NOW),
                                        ("closed", NOW, "merged " + NOW),
                                        (None, None, "unknown")]:
            client = WatchClient()
            client.queries = []
            client.watched = (dict(title="Blob store", state=state, updated_at=NOW if state == "open" else SINCE,
                                  closed_at=NOW, pull_request=dict(merged_at=merged)) if state else None)
            text = morning.sweep(client, SINCE, "example-user")
            watch = text.split("## Watched items\n")[1].split("\n## ")[0]
            self.assertIn("upstream/engine#2595", watch)
            self.assertIn(expected, watch)
            self.assertIn("upstream/runtime#4 Watched item: open, updated " + NOW, watch)
            self.assertEqual(sum(call[-1].endswith("/issues/2595") for call in client.calls), 1)
            for query in client.queries:
                if "is:pr created:" in query or "is:pr is:merged" in query and "author:" not in query:
                    self.assertIn("repo:upstream/runtime", query)

    def test_bot_merged_pr_references_are_skipped(self):
        class BotClient(SweepClient):
            def gh(self, *args, host=None, budget_optional=False):
                if args[-1].endswith("/pulls/216"):
                    return dict(title="Refs #1", body="", merged_at=NOW,
                                merged_by=dict(login="merger-user", type="User"))
                if args[-1].endswith("/issues/1"):
                    self.calls.append(args)
                    return dict(state="open", title="Bot noise")
                return super().gh(*args, host=host)

        for login, kind in [("dependabot[bot]", "Bot"), ("other[bot]", "User"), ("service", "Bot")]:
            item = sweep_item(216, login, pr=True)
            item["user"]["type"] = kind
            client = BotClient(merged=[item])
            text = morning.sweep(client, SINCE, "example-user")
            section = text.split("## Open issues referenced by PRs merged since the last run\n")[1].split("\n## ")[0]
            self.assertIn("Nothing new", section)
            self.assertFalse(any(str(call[-1]).endswith("/issues/1") for call in client.calls))

    def test_issue_budget_is_independent_and_skips_are_collapsed(self):
        class IssueClient(SweepClient):
            def gh(self, *args, host=None, budget_optional=False):
                self.calls.append(args)
                return dict(state="open", title="Open issue")

        client = IssueClient()
        activity = morning.Activity(client, SINCE, "example-user")
        activity.items = {("owner", "repo", str(n)) for n in range(100)}
        merged = {("example/sessions", 216): dict(title="Refs #1; #2; #3; #4",
                  body="https://github.com/untracked/project/issues/5")}
        lines = morning.referenced_open_issues(activity, merged, limit=2)
        self.assertIn('sessions#1 Open issue — PR #216 "Refs"', lines[0])
        self.assertIn("sessions#2 Open issue — PR #216 mention", lines[1])
        self.assertEqual(lines[2:], ["- 2 references not checked (lookup budget): example/sessions#3, example/sessions#4"])
        self.assertEqual(len(client.calls), 2)
        self.assertFalse(client.activity_failures)

    def test_issue_deduplication_keeps_all_source_prs_and_one_lookup(self):
        class IssueClient(SweepClient):
            def gh(self, *args, host=None, budget_optional=False):
                self.calls.append(args)
                return dict(state="open", title="Open issue")

        client = IssueClient()
        merged = {("example/sessions", 216): dict(title="Refs #1", body="#1"),
                  ("example/sessions", 217): dict(title="", body="#1")}
        lines = morning.referenced_open_issues(morning.Activity(client, SINCE, "example-user"), merged)
        self.assertEqual(lines, ['- example/sessions#1 Open issue — PR #216 "Refs"; PR #217 mention'])
        self.assertEqual(len(client.calls), 1)

    def test_issue_lookups_run_after_existing_activity_sections(self):
        class OrderClient(SweepClient):
            def search(self, query, host=None):
                self.calls.append(query)
                return super().search(query, host=host)

        client = OrderClient(merged=[sweep_item(216, pr=True)])
        morning.sweep(client, SINCE, "example-user")
        extra_merges = next(i for i, call in enumerate(client.calls) if "-author:example-user" in str(call)
                            and "is:merged" in str(call))
        existing = next(i for i, call in enumerate(client.calls) if "is:pr is:open author:example-user" in str(call))
        self.assertGreater(extra_merges, existing)

    def test_own_bot_and_old_activity_drops_out(self):
        for events in ([comment("example-user")], [comment("some-service", "Bot")],
                       [comment("copilot")], [comment("outside-user", timestamp="2026-10-24T00:00:00Z")]):
            with self.subTest(events=events):
                self.assertIn("Nothing new", self.filtered(SweepClient([sweep_item(77)], events)))

    def test_comment_review_and_inline_show_actor_and_time(self):
        for field in ("comments", "reviews", "inline"):
            with self.subTest(field=field):
                client = SweepClient([sweep_item(77, pr=True)], **{field: [comment("outside-user")]})
                text = self.filtered(client)
                self.assertIn("outside-user", text)
                self.assertIn(NOW, text)
                self.assertIn("sessions#77", text)

    def test_failed_lookup_is_unknown_not_nothing(self):
        client = SweepClient([sweep_item(77)], fail="/comments")
        text = morning.sweep(client, SINCE, "example-user")
        self.assertIn("unknown", self.filtered(SweepClient([sweep_item(77)], fail="/comments")))
        summary = text.split("## Summary\n")[1].split("\n## ")[0]
        self.assertIn("Failed queries: 1", summary)
        self.assertIn("offline", text)

    def test_summary_first_capped_with_overflow_and_all_sections_kept(self):
        client = SweepClient([sweep_item(n) for n in range(20)], [comment("outside-user")])
        text = morning.sweep(client, SINCE, "example-user")
        self.assertEqual(next(line for line in text.splitlines() if line.startswith("## ")), "## Summary")
        summary = text.split("## Summary\n")[1].split("\n## ")[0]
        self.assertLessEqual(len([line for line in summary.splitlines() if line.strip()]) + 1, 10)
        self.assertIn("more", summary)
        self.assertIn("20", summary)
        for title in ("Review requested from you", "Your open PRs", "New issues",
                      "Notifications outside the repo list", "Internal tracker (git.example.test)"):
            self.assertIn("## " + title, text)

    def test_summary_uses_merger_not_author_and_includes_new_issue(self):
        client = SweepClient(opened=[sweep_item(220, "outside-user")], merged=[sweep_item(216, pr=True)])
        summary = morning.sweep(client, SINCE, "example-user").split("## Summary\n")[1].split("\n## ")[0]
        self.assertIn("outside-user", summary)
        self.assertIn("sessions#220", summary)
        self.assertIn("merger-user", summary)
        self.assertIn("sessions#216", summary)

    def test_failed_merger_lookup_does_not_double_count_items(self):
        client = SweepClient(merged=[sweep_item(216, pr=True)], fail="/pulls/216")
        text = morning.sweep(client, SINCE, "example-user")
        summary = text.split("## Summary\n")[1].split("\n## ")[0]
        self.assertIn("Merged: 1;", summary)
        self.assertIn("Failed queries: 1", summary)
        self.assertIn("merger unknown", text)

    def test_summary_collapses_repeat_comments_but_details_keep_times(self):
        events = [comment("outside-user", timestamp=f"2026-10-26T07:{n:02d}:00Z") for n in range(20)]
        text = morning.sweep(SweepClient([sweep_item(77)], events), SINCE, "example-user")
        summary = text.split("## Summary\n")[1].split("\n## ")[0]
        self.assertEqual(summary.count("outside-user: commented"), 1)
        self.assertIn("07:19:00Z", summary)
        self.assertIn("07:00:00Z", self.filtered(SweepClient([sweep_item(77)], events)))

    def test_internal_summary_uses_host_identity_to_exclude_self(self):
        class InternalClient(SweepClient):
            def search(self, query, host=None):
                if host == "git.example.test":
                    item = sweep_item(98, "internal-user")
                    item["repository_url"] = "https://git.example.test/api/v3/repos/example/tracker"
                    return [item]
                return []

            def gh(self, *args, host=None, budget_optional=False):
                if args == ("api", "user"):
                    return dict(login="internal-user")
                return super().gh(*args, host=host)

        client = InternalClient(comments=[comment("internal-user"), comment("outside-user")])
        text = morning.sweep(client, SINCE, "example-user")
        summary = text.split("## Summary\n")[1].split("\n## ")[0]
        self.assertIn("tracker#98", summary)
        self.assertIn("outside-user", summary)
        self.assertNotIn("internal-user", summary)

    def test_comment_fetch_reused_across_sections(self):
        client = SweepClient([sweep_item(77)], [comment("outside-user")])
        morning.sweep(client, SINCE, "example-user")
        morning.new_comments(client, [sweep_item(77)], SINCE)
        self.assertEqual(sum("/issues/77/comments" in str(call) for call in client.calls), 1)

    def test_lookup_budget_reports_skips_as_unknown(self):
        client = SweepClient([sweep_item(n) for n in range(102)])
        text = morning.sweep(client, SINCE, "example-user")
        self.assertIn("lookup limit", text)
        self.assertIn("unknown", text)
        self.assertTrue(client.failures)
        self.assertLessEqual(sum("/issues/" in str(call) and str(call[-1]).endswith("/comments")
                                 for call in client.calls), 100)


class TrackedSeriesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name)
        self.tracker = self.root / "items.csv"
        self.tracker.write_text('issue,item,summary\n77,B1,"already, tracked"\n77,B2,repeat\n')
        self.series = [{"repo": "example/sessions", "title": "Post-merge review",
                        "tracker": "items.csv"}]
        state = patch.dict(morning.__dict__)
        state.start()
        self.addCleanup(state.stop)

    def configure(self, **extra):
        (self.root / "coordination.json").write_text(json.dumps({
            "repos": ["example/sessions"], **extra}))
        morning.configure(self.root)

    def run_sweep(self, items=(), fail=False):
        class Client(SweepClient):
            def gh(client, *args, host=None, budget_optional=False):
                if "repos/example/sessions/issues" in args:
                    client.calls.append(args)
                    if fail:
                        client.fail("series issues", "offline")
                        return None
                    return [list(items)]
                return super().gh(*args, host=host, budget_optional=budget_optional)

        client = Client()
        text = morning.sweep(client, SINCE, "example-user")
        return text, client

    def issue(self, number, **extra):
        return dict(sweep_item(number), title="Post-merge review: older batch",
                    state="open", created_at="2026-01-01T00:00:00Z", **extra)

    def section(self, text):
        self.assertIn("## Untriaged: Post-merge review\n", text)
        return text.split("## Untriaged: Post-merge review\n")[1].split("\n## ")[0]

    def test_untracked_old_issue_is_listed_with_link_title_date_and_summary_count(self):
        self.configure(tracked_series=self.series)
        text, client = self.run_sweep([self.issue(78)])
        self.assertIn("[example/sessions#78](https://github.com/example/sessions/issues/78)",
                      self.section(text))
        self.assertIn("Post-merge review: older batch", self.section(text))
        self.assertIn("2026-01-01T00:00:00Z", self.section(text))
        self.assertIn("Untriaged: Post-merge review: 1\n", text.split("## Summary\n")[1].split("\n## ")[0])
        call = next(call for call in client.calls if "repos/example/sessions/issues" in call)
        self.assertIn("repos/example/sessions/issues", call)

    def test_tracked_issue_is_not_listed(self):
        self.configure(tracked_series=self.series)
        text, _ = self.run_sweep([self.issue(77)])
        self.assertIn("Nothing new", self.section(text))
        self.assertNotIn("sessions#77", self.section(text))

    def test_closed_issues_prs_and_nonprefix_titles_are_not_listed(self):
        self.configure(tracked_series=self.series)
        closed = self.issue(78)
        closed["state"] = "closed"
        wrong_title = self.issue(79)
        wrong_title["title"] = "Follow-up Post-merge review"
        pr = self.issue(80, pull_request={})
        text, _ = self.run_sweep([closed, wrong_title, pr])
        self.assertIn("Nothing new", self.section(text))

    def test_absent_key_preserves_output_and_calls_byte_for_byte(self):
        self.configure()
        before, client_before = self.run_sweep()
        self.configure(tracked_series=[])
        after, client_after = self.run_sweep()
        self.assertEqual(after, before)
        self.assertEqual(client_after.calls, client_before.calls)
        self.assertNotIn("Untriaged", before)

    def test_bad_config_is_refused_without_changing_configuration(self):
        self.configure(tracked_series=self.series)
        for value in (None, {}, [None], [{}], [{**self.series[0], "repo": "bad repo"}],
                      [{**self.series[0], "title": " "}], [{**self.series[0], "title": 7}],
                      [{**self.series[0], "tracker": ""}], [{**self.series[0], "tracker": []}],
                      [{**self.series[0], "typo": True}]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "tracked_series"):
                self.configure(tracked_series=value)
        text, _ = self.run_sweep([self.issue(78)])
        self.assertIn("sessions#78", self.section(text))

    def test_missing_tracker_is_unknown_and_reported_as_failure(self):
        self.configure(tracked_series=self.series)
        self.tracker.unlink()
        text, client = self.run_sweep()
        self.assertIn("unknown", self.section(text))
        self.assertNotIn("Nothing new", self.section(text))
        self.assertIn("Untriaged: Post-merge review: unknown", text)
        self.assertIn("## Failed queries", text)
        self.assertIn(self.tracker.name, text)
        self.assertEqual(len(client.failures), 1)

    def test_unreruntimeble_or_malformed_tracker_is_reported_as_failure(self):
        self.configure(tracked_series=self.series)
        for contents in ("", "wrong,header\n77,B1\n", "issue\nnot-a-number\n", "issue\n\xff"):
            self.tracker.write_bytes(contents.encode("latin1"))
            with self.subTest(contents=contents):
                text, client = self.run_sweep()
                self.assertIn("unknown", self.section(text))
                self.assertEqual(len(client.failures), 1)
        self.tracker.unlink()
        self.tracker.mkdir()
        text, client = self.run_sweep()
        self.assertIn("unknown", self.section(text))
        self.assertEqual(len(client.failures), 1)

    def test_failed_issue_query_is_unknown_not_nothing_new(self):
        self.configure(tracked_series=self.series)
        text, client = self.run_sweep(fail=True)
        self.assertIn("unknown", self.section(text))
        self.assertNotIn("Nothing new", self.section(text))
        self.assertIn("Untriaged: Post-merge review: unknown", text)
        self.assertIn("offline", text)
        self.assertEqual(len(client.failures), 1)


class RequestAccountingTests(unittest.TestCase):
    def test_reference_activity_request_accounting(self):
        """Orchestration counts for specified fixtures, not a worst-case bound."""
        class Counting(SweepClient):
            def __init__(self, activity, pages):
                super().__init__()
                self.activity, self.comment_pages, self.count = activity, pages, 0

            def search(self, query, host=None):
                self.count += 1
                if self.activity == 0:
                    return []
                if 'involves:' in query:
                    return [sweep_item(1000+n, pr=True) for n in range(self.activity)]
                if 'is:pr is:open author:' in query:
                    return [sweep_item(3000+n, pr=True) for n in range(10)]
                if 'is:merged' in query and 'author:' not in query:
                    return [sweep_item(2000+n, pr=True) for n in range(10)]
                return []

            def pr(self, repo, number):
                self.count += 1
                return dict(state='OPEN', isDraft=False, headRefOid='a'*40, statusCheckRollup=[],
                            reviewDecision=None, mergeStateStatus='CLEAN', url='https://github.com/example/project/pull/1')

            def human_threads(self, repo, number):
                self.count += 1
                return 0

            def gh(self, *args, host=None, budget_optional=False):
                endpoint = args[-1]
                self.count += self.comment_pages if endpoint.endswith('/comments') else (3 if self.activity else 1) if endpoint == 'notifications' else 1
                if endpoint == 'notifications':
                    return [[]]
                if endpoint.endswith('/comments') or endpoint.endswith('/reviews'):
                    return [[]]
                if '/pulls/' in endpoint:
                    return dict(title='Merge', body='Refs '+ ' '.join('#'+str(n) for n in range(1,26)),
                                merged_by={'login':'merger-user','type':'User'}, merged_at=NOW)
                if '/issues/' in endpoint:
                    return dict(state='open', title='Issue', updated_at=NOW)
                return dict(login='example-user')

        for activity, pages, expected in ((0,1,17),(10,1,114),(80,1,324),(80,2,484)):
            with self.subTest(activity=activity, pages=pages), patch.dict(morning.__dict__):
                morning.REPOS = ('example/sessions', 'upstream/engine')
                morning.OURS, morning.OWN_ONLY = {'example/sessions'}, {'upstream/engine'}
                morning.WATCH = tuple(('example/sessions',9000+n) for n in range(6))
                morning.NOTIFICATIONS, morning.INTERNAL_TRACKER = True, False
                morning.TRACKED_SERIES = []
                client = Counting(activity, pages)
                client.gh('api','user')
                morning.sweep(client, SINCE, 'example-user')
                self.assertEqual(client.count, expected)
                self.assertFalse(client.activity_failures)


if __name__ == "__main__":
    unittest.main()
