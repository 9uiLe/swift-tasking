from contextlib import redirect_stdout
from copy import deepcopy
from datetime import date
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import (BRANCH, INSTALLATION, OWNER, RELEASE_HEADING, REMOTE, REPOSITORY, REQUIRED_JOBS, WORKFLOW,
                     Release, ReleaseError, prepare_documents, release_notes,
                     successful_run, validate_jobs, version_key)


UNRELEASED = f"""# Changelog

## [Unreleased]

### Changed

- Define task shutdown contracts.

## [0.2.0] - 2026-07-15

- Previous release.

[Unreleased]: https://github.com/{REPOSITORY}/compare/0.2.0...HEAD
[0.2.0]: https://github.com/{REPOSITORY}/releases/tag/0.2.0
"""
README = f'.package(url: "{REMOTE}", from: "0.2.0")\n'
CHANGELOG, RELEASE_README = prepare_documents(UNRELEASED, README, "0.3.0", date(2026, 9, 16))
NOTES = "### Changed\n\n- Define task shutdown contracts."


def ci_run(commit):
    return dict(id=10, workflow_id=20, path=WORKFLOW, event="push",
                head_branch=BRANCH, head_sha=commit,
                head_repository={"full_name": REPOSITORY}, run_number=3,
                run_attempt=1, status="completed", conclusion="success",
                html_url="https://github.com/example/actions/runs/10")


def ci_jobs(commit):
    return [dict(name=name, conclusion="success", head_sha=commit) for name in sorted(REQUIRED_JOBS)]


class DocumentTests(unittest.TestCase):
    def test_repository_documents_can_be_prepared_or_checked_without_manual_reformatting(self):
        root = Path(__file__).resolve().parents[2]
        changelog = (root / "CHANGELOG.md").read_text()
        readme = (root / "README.md").read_text()
        latest = RELEASE_HEADING.search(changelog)
        self.assertIsNotNone(latest)
        dependencies = INSTALLATION.findall(readme)
        self.assertEqual(len(dependencies), 1)
        self.assertEqual(dependencies[0][1], latest.group(1))
        pending = changelog.split("## [Unreleased]\n")[1].split(latest.group(0), 1)[0].strip()
        if pending:
            major, minor, _ = version_key(latest.group(1))
            version = f"{major}.{minor + 1}.0"
            prepared, dependency = prepare_documents(changelog, readme, version, date(2026, 9, 16))
            self.assertEqual(release_notes(prepared, version), pending)
            self.assertEqual(INSTALLATION.findall(dependency)[0][1], version)
        else:
            self.assertTrue(release_notes(changelog, latest.group(1)))

    def test_preparation_dates_notes_updates_dependency_and_preserves_old_releases(self):
        self.assertIn("## [Unreleased]\n\n## [0.3.0] - 2026-09-16", CHANGELOG)
        self.assertEqual(release_notes(CHANGELOG, "0.3.0"), NOTES)
        self.assertIn("compare/0.2.0...0.3.0", CHANGELOG)
        self.assertIn("compare/0.3.0...HEAD", CHANGELOG)
        self.assertIn(UNRELEASED[UNRELEASED.index("## [0.2.0]"):].split("[Unreleased]:")[0], CHANGELOG)
        self.assertEqual(RELEASE_README, README.replace("0.2.0", "0.3.0"))

    def test_only_stable_semantic_versions_are_accepted(self):
        self.assertGreater(version_key("0.10.0"), version_key("0.9.9"))
        for version in ("v0.3.0", "0.3", "01.3.0", "0.3.0-rc.1", "0.3.0+build", "../x", "0.3.0\n"):
            with self.subTest(version=version), self.assertRaises(ReleaseError):
                version_key(version)

    def test_preparation_rejects_missing_notes_ambiguous_dependency_and_old_version(self):
        cases = [
            (UNRELEASED.replace("- Define task shutdown contracts.", ""), README, "0.3.0"),
            (UNRELEASED, "no dependency", "0.3.0"),
            (UNRELEASED, README * 2, "0.3.0"),
            (UNRELEASED, README, "0.2.0"),
            (UNRELEASED.replace("0.2.0...HEAD", "0.1.0...HEAD"), README, "0.3.0"),
            (UNRELEASED.replace("## [Unreleased]", "## Changes"), README, "0.3.0"),
        ]
        for changelog, readme, version in cases:
            with self.subTest(changelog=changelog, readme=readme, version=version), self.assertRaises(ReleaseError):
                prepare_documents(changelog, readme, version, date.today())

    def test_publication_requires_latest_release_notes_and_a_valid_date(self):
        for changelog, version in ((CHANGELOG, "0.2.0"), (CHANGELOG.replace("09-16", "02-30"), "0.3.0"),
                                   (CHANGELOG.replace("- Define task shutdown contracts.", ""), "0.3.0")):
            with self.subTest(version=version), self.assertRaises((ReleaseError, ValueError)):
                release_notes(changelog, version)


class CIValidationTests(unittest.TestCase):
    def test_only_the_exact_repository_workflow_event_branch_and_commit_can_qualify(self):
        for field, value in {"workflow_id": 99, "path": "other.yml", "event": "pull_request",
                             "head_branch": "release/0.3.0", "head_sha": "b" * 40,
                             "head_repository": {"full_name": "fork/package"}}.items():
            run = ci_run("a" * 40)
            run[field] = value
            with self.subTest(field=field), self.assertRaises(ReleaseError):
                successful_run([run], 20, "a" * 40)

    def test_a_previous_success_cannot_hide_a_failed_or_running_retry(self):
        old = ci_run("a" * 40)
        for status, conclusion in (("completed", "failure"), ("in_progress", None), ("completed", "cancelled")):
            newer = dict(old, run_attempt=2, status=status, conclusion=conclusion)
            with self.subTest(status=status, conclusion=conclusion), self.assertRaises(ReleaseError):
                successful_run([newer, old], 20, "a" * 40)
        newer = dict(old, run_number=4, conclusion="failure")
        with self.assertRaises(ReleaseError):
            successful_run([old, newer], 20, "a" * 40)

    def test_missing_duplicate_skipped_failed_or_wrong_commit_jobs_are_rejected(self):
        jobs = ci_jobs("a" * 40)
        invalid = [jobs[:1], jobs + jobs[:1]]
        for field, value in (("conclusion", "skipped"), ("conclusion", "failure"), ("head_sha", "b" * 40)):
            changed = deepcopy(jobs)
            changed[0][field] = value
            invalid.append(changed)
        for candidate in invalid:
            with self.subTest(jobs=candidate), self.assertRaises(ReleaseError):
                validate_jobs(candidate, "a" * 40)
        validate_jobs(jobs, "a" * 40)


class SandboxRelease(Release):
    def __init__(self, root, remote):
        super().__init__(root)
        self.remote = remote
        self.master = self.git("rev-parse", "HEAD")
        self.origin = REMOTE
        self.login = OWNER
        self.repository = dict(full_name=REPOSITORY, visibility="public", default_branch=BRANCH,
                               permissions={"admin": True})
        self.immutable = True
        self.tags = {"0.2.0": self.master}
        self.tag_objects = {}
        self.releases = []
        self.branches = {}
        self.runs = [ci_run(self.master)]
        self.jobs = ci_jobs(self.master)
        self.reads = []
        self.writes = []
        self.fail = None
        self.move_tag_on_draft = False

    def api(self, path, *, method="GET", data=None, missing=False):
        parsed = urlsplit(path)
        route = parsed.path.removeprefix(f"repos/{REPOSITORY}/")
        self.reads.append(path)
        if method != "GET":
            self.writes.append((method, route, data))
            if self.fail == route:
                raise ReleaseError("simulated network failure")
            if route == "git/tags":
                self.tag_objects["c" * 40] = data
                return {"sha": "c" * 40}
            if route == "git/refs":
                self.tags[data["ref"].removeprefix("refs/tags/")] = self.tag_objects[data["sha"]]["object"]
                return {}
            raise AssertionError((method, route, data))
        if route == "user":
            return {"login": self.login}
        if route == f"repos/{REPOSITORY}":
            return self.repository
        if route == "immutable-releases":
            return {"enabled": True} if self.immutable else None
        if route.startswith("git/ref/tags/"):
            version = route.removeprefix("git/ref/tags/")
            return {"object": {"type": "tag", "sha": version}} if version in self.tags else None
        if route.startswith("git/tags/"):
            version = route.removeprefix("git/tags/")
            return {"tag": version, "object": {"type": "commit", "sha": self.tags[version]}}
        if route == f"git/ref/heads/{BRANCH}":
            return {"object": {"sha": self.master}}
        if route.startswith("git/ref/heads/"):
            return self.branches.get(route.removeprefix("git/ref/heads/"))
        if route == "tags":
            return [{"name": version} for version in self.tags]
        if route == "releases":
            page = int(parse_qs(parsed.query)["page"][0])
            return deepcopy(self.releases[(page - 1) * 100:page * 100])
        if route == "actions/workflows/ci.yml":
            return {"id": 20, "path": WORKFLOW, "state": "active"}
        if route == "actions/workflows/20/runs":
            return {"workflow_runs": self.runs}
        if route == "actions/runs/10/attempts/1/jobs":
            return {"jobs": self.jobs}
        raise AssertionError((method, path))

    def run(self, *arguments, **kwargs):
        if arguments == ("git", "remote", "get-url", "origin"):
            return self.origin
        if arguments[:2] == ("git", "-c") and ("fetch" in arguments or "push" in arguments):
            if "push" in arguments:
                self.writes.append(("push", arguments))
            arguments = tuple(str(self.remote) if arg == REMOTE else arg for arg in arguments)
        if arguments[0] != "gh":
            return super().run(*arguments, **kwargs)
        self.writes.append(arguments[:3])
        operation = arguments[2]
        if self.fail == operation:
            raise ReleaseError("simulated network failure")
        if arguments[1:3] == ("release", "create"):
            self.releases.append(dict(id=30, tag_name=arguments[3],
                                      target_commitish=arguments[arguments.index("--target") + 1],
                                      author={"login": self.login}, draft=True, prerelease=False, assets=[],
                                      body=Path(arguments[arguments.index("--notes-file") + 1]).read_text(),
                                      immutable=False, html_url="https://github.com/example/releases/tag/0.3.0"))
            if self.move_tag_on_draft:
                self.tags["0.3.0"] = "d" * 40
            return "draft"
        if arguments[1:3] == ("release", "edit"):
            self.releases[-1].update(draft=False, immutable=self.immutable)
            return "published"
        if arguments[1:3] == ("pr", "create"):
            self.pr_body = Path(arguments[arguments.index("--body-file") + 1]).read_text()
            self.pr_arguments = arguments
            return "https://github.com/example/pull/1"
        raise AssertionError(arguments)


class ReleaseFlowTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"GITHUB_ACTIONS": "false"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.output = redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)
        self.temporary = tempfile.TemporaryDirectory(prefix="release-test-")
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        self.root = directory / "checkout"
        self.remote = directory / "remote.git"
        self.root.mkdir()
        subprocess.run(["git", "init", "--bare", str(self.remote)], check=True, capture_output=True)
        local = Release(self.root)
        local.git("init", "-b", BRANCH)
        local.git("config", "user.name", "Release Test")
        local.git("config", "user.email", "release-test@example.invalid")
        local.git("config", "commit.gpgsign", "false")
        local.git("remote", "add", "origin", str(self.remote))
        (self.root / "CHANGELOG.md").write_text(CHANGELOG)
        (self.root / "README.md").write_text(RELEASE_README)
        local.git("add", ".")
        local.git("commit", "-m", "Fixture release")
        local.git("push", "origin", BRANCH)
        self.release = SandboxRelease(self.root, self.remote)

    def commit_documents(self, changelog, readme):
        (self.root / "CHANGELOG.md").write_text(changelog)
        (self.root / "README.md").write_text(readme)
        self.release.git("add", ".")
        self.release.git("commit", "-m", "Fixture update")
        self.release.git("push", "origin", BRANCH)
        self.release.master = self.release.git("rev-parse", "HEAD")

    def assert_stops_without_writes(self, message=None):
        with self.assertRaises(ReleaseError) as caught:
            self.release.publish("0.3.0")
        if message:
            self.assertIn(message, str(caught.exception))
        self.assertEqual(self.release.writes, [])

    def test_check_reads_the_committed_source_and_makes_no_remote_writes(self):
        plan = self.release.plan("0.3.0")
        self.assertEqual(plan.commit, self.release.master)
        self.assertEqual(plan.notes, NOTES)
        self.assertEqual(self.release.writes, [])
        self.assertTrue(any("/attempts/1/jobs" in path for path in self.release.reads))

    def test_ssh_origin_fetches_through_owner_authenticated_https(self):
        self.release.origin = f"git@github.com:{REPOSITORY}.git"
        with patch.object(self.release, "run", wraps=self.release.run) as calls:
            self.release.plan("0.3.0")
        fetches = [call.args for call in calls.call_args_list if "fetch" in call.args]
        self.assertEqual(len(fetches), 1)
        fetch = fetches[0]
        self.assertEqual(fetch[fetch.index("fetch") + 1], REMOTE)
        self.assertIn("credential.https://github.com.helper=!gh auth git-credential", fetch)
        self.assertEqual(self.release.writes, [])

    def test_publishing_creates_an_annotated_tag_then_a_draft_then_an_immutable_release(self):
        self.release.publish("0.3.0")
        self.assertEqual(self.release.tags["0.3.0"], self.release.master)
        self.assertEqual([write[:2] for write in self.release.writes],
                         [("POST", "git/tags"), ("POST", "git/refs"), ("gh", "release"), ("gh", "release")])
        self.assertEqual(self.release.tag_objects["c" * 40]["type"], "commit")
        self.assertFalse(self.release.releases[0]["draft"])
        self.assertTrue(self.release.releases[0]["immutable"])

    def test_published_release_is_idempotent_even_after_master_advances(self):
        self.release.publish("0.3.0")
        self.commit_documents(CHANGELOG + "\n", RELEASE_README)
        self.release.writes.clear()
        self.release.publish("0.3.0")
        self.assertEqual(self.release.writes, [])

    def test_a_tag_or_draft_failure_can_resume_after_master_advances(self):
        for operation in ("create", "edit"):
            with self.subTest(operation=operation):
                self.release.tags.pop("0.3.0", None)
                self.release.releases.clear()
                self.release.runs = [ci_run(self.release.master)]
                self.release.jobs = ci_jobs(self.release.master)
                self.release.fail = operation
                with self.assertRaises(ReleaseError):
                    self.release.publish("0.3.0")
                original = self.release.tags["0.3.0"]
                self.commit_documents(CHANGELOG + "\n" * (2 if operation == "edit" else 1), RELEASE_README)
                self.release.fail = None
                self.release.writes.clear()
                self.release.publish("0.3.0")
                self.assertEqual(self.release.tags["0.3.0"], original)
                self.assertTrue(self.release.releases[0]["immutable"])
                self.assertFalse(any(write[0] == "POST" for write in self.release.writes))

    def test_failed_tag_reference_creation_leaves_no_release_and_can_retry(self):
        self.release.fail = "git/refs"
        with self.assertRaises(ReleaseError):
            self.release.publish("0.3.0")
        self.assertNotIn("0.3.0", self.release.tags)
        self.assertEqual(self.release.releases, [])
        self.release.fail = None
        self.release.publish("0.3.0")
        self.assertEqual(self.release.tags["0.3.0"], self.release.master)
        self.assertTrue(self.release.releases[0]["immutable"])

    def test_wrong_owner_repository_permissions_visibility_branch_and_origin_stop_publication(self):
        for key, value in (("full_name", "fork/package"), ("visibility", "private"),
                           ("default_branch", "main"), ("permissions", {"admin": False})):
            previous = self.release.repository[key]
            self.release.repository[key] = value
            with self.subTest(key=key):
                self.assert_stops_without_writes()
            self.release.repository[key] = previous
        self.release.login = "someone-else"
        self.assert_stops_without_writes("Authenticate gh")
        self.release.login = OWNER
        self.release.origin = "https://github.com/fork/package.git"
        self.assert_stops_without_writes("origin must")

    def test_dirty_worktree_and_actions_environment_stop_before_authentication(self):
        (self.root / "untracked").write_text("change")
        self.assert_stops_without_writes("working-tree")
        self.assertEqual(self.release.reads, [])
        (self.root / "untracked").unlink()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            self.assert_stops_without_writes("locally")
        self.assertEqual(self.release.reads, [])

    def test_failed_ci_missing_jobs_and_disabled_immutability_cannot_create_tags(self):
        self.release.runs[0]["conclusion"] = "failure"
        self.assert_stops_without_writes("has not succeeded")
        self.release.runs[0]["conclusion"] = "success"
        jobs = self.release.jobs
        self.release.jobs = jobs[:1]
        self.assert_stops_without_writes("must succeed")
        self.release.jobs = jobs
        self.release.immutable = False
        self.assert_stops_without_writes("Immutable releases")

    def test_unmerged_release_documents_cannot_create_tags(self):
        self.commit_documents(UNRELEASED, README)
        self.assert_stops_without_writes("first CHANGELOG release")

    def test_new_unreleased_changes_cannot_be_published_under_the_prepared_version(self):
        self.commit_documents(CHANGELOG.replace("## [Unreleased]\n", "## [Unreleased]\n\n- Later change.\n"), RELEASE_README)
        self.assert_stops_without_writes("Unreleased must be empty")

    def test_a_tag_outside_master_cannot_be_published(self):
        tree = self.release.git("rev-parse", "HEAD^{tree}")
        self.release.tags["0.3.0"] = self.release.git("commit-tree", tree, "-m", "Unrelated root")
        self.assert_stops_without_writes()

    def test_readme_must_install_the_release_version(self):
        self.commit_documents(CHANGELOG, README)
        self.assert_stops_without_writes("README")

    def test_an_existing_newer_version_prevents_publication(self):
        self.release.tags["0.4.0"] = self.release.master
        self.assert_stops_without_writes("newer or equal")

    def test_existing_release_with_different_owner_commit_notes_assets_or_immutability_is_rejected(self):
        self.release.publish("0.3.0")
        original = deepcopy(self.release.releases[0])
        self.release.writes.clear()
        for key, value in (("author", {"login": "someone-else"}), ("target_commitish", "master"),
                           ("body", "Different notes"), ("assets", [{"name": "binary"}]),
                           ("prerelease", True), ("immutable", False)):
            self.release.releases = [dict(original, **{key: value})]
            with self.subTest(key=key):
                self.assert_stops_without_writes()

    def test_release_without_an_annotated_tag_is_rejected(self):
        self.release.publish("0.3.0")
        self.release.tags.pop("0.3.0")
        self.release.writes.clear()
        self.assert_stops_without_writes("without the expected annotated tag")

    def test_a_tag_changed_or_deleted_after_validation_cannot_be_recreated(self):
        plan = self.release.plan("0.3.0")
        for value in (None, "b" * 40):
            self.release.tags["0.3.0"] = self.release.master
            existing_plan = self.release.plan("0.3.0")
            with patch.object(self.release, "plan", return_value=existing_plan), patch.object(self.release, "tag", return_value=value):
                self.assert_stops_without_writes()
        self.release.tags.pop("0.3.0")
        self.release.master = "b" * 40
        with patch.object(self.release, "plan", return_value=plan):
            self.assert_stops_without_writes("master changed")

    def test_a_tag_moved_while_creating_the_draft_cannot_be_published(self):
        self.release.move_tag_on_draft = True
        with self.assertRaisesRegex(ReleaseError, "before publication"):
            self.release.publish("0.3.0")
        self.assertTrue(self.release.releases[0]["draft"])
        self.assertNotIn(("gh", "release", "edit"), self.release.writes)

    def test_release_lookup_finds_drafts_on_later_pages_and_rejects_duplicates(self):
        self.release.releases = [{"tag_name": f"old-{index}"} for index in range(100)]
        draft = {"tag_name": "0.3.0", "draft": True}
        self.release.releases.append(draft)
        self.assertEqual(self.release.find_release("0.3.0"), draft)
        self.release.releases.append(draft)
        with self.assertRaises(ReleaseError):
            self.release.find_release("0.3.0")

    def test_prepare_dry_run_preserves_files_branches_and_remote_state(self):
        self.commit_documents(UNRELEASED, README)
        before = self.release.git("rev-parse", "HEAD")
        self.release.prepare("0.3.0", dry_run=True)
        self.assertEqual(self.release.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.release.git("branch", "--show-current"), BRANCH)
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), UNRELEASED)
        self.assertEqual(self.release.writes, [])

    def test_prepare_commits_and_pushes_versioned_documents_and_opens_a_pr(self):
        self.commit_documents(UNRELEASED, README)
        self.release.prepare("0.3.0")
        self.assertEqual(self.release.git("branch", "--show-current"), "release/0.3.0")
        self.assertEqual(self.release.git("status", "--porcelain"), "")
        self.assertEqual(release_notes((self.root / "CHANGELOG.md").read_text(), "0.3.0"), NOTES)
        self.assertEqual((self.root / "README.md").read_text(), RELEASE_README)
        self.assertIn(self.release.git("rev-parse", "HEAD"), self.release.git("ls-remote", "origin", "refs/heads/release/0.3.0"))
        self.assertIn("\n\n", self.release.pr_body)
        self.assertNotIn("\\n", self.release.pr_body)
        args = self.release.pr_arguments
        self.assertEqual(args[args.index("--base") + 1], BRANCH)
        self.assertEqual(args[args.index("--head") + 1], "release/0.3.0")
        with self.assertRaisesRegex(ReleaseError, "already exists"):
            self.release.prepare("0.3.0")

    def test_prepare_uses_the_validated_commit_if_the_tracking_ref_advances(self):
        self.commit_documents(UNRELEASED, README)
        validated = self.release.master
        tree = self.release.git("rev-parse", "HEAD^{tree}")
        advanced = self.release.git("commit-tree", tree, "-p", validated, "-m", "Concurrent update")
        source = self.release.source

        def source_while_fetch_advances(commit, path):
            content = source(commit, path)
            self.release.git("update-ref", f"refs/remotes/origin/{BRANCH}", advanced)
            return content

        with patch.object(self.release, "source", side_effect=source_while_fetch_advances):
            self.release.prepare("0.3.0")
        self.assertEqual(self.release.git("rev-parse", "HEAD^"), validated)


class TransportTests(unittest.TestCase):
    def test_only_an_explicit_404_can_be_treated_as_absent(self):
        release = Release(Path.cwd())
        for code in (403, 429, 500):
            result = subprocess.CompletedProcess([], 1, "", f"gh: failed (HTTP {code})")
            with self.subTest(code=code), patch("release.subprocess.run", return_value=result), self.assertRaises(ReleaseError):
                release.api("user", missing=True)
        missing = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        with patch("release.subprocess.run", return_value=missing):
            self.assertIsNone(release.api("missing", missing=True))
            with self.assertRaises(ReleaseError):
                release.api("missing")

    def test_lightweight_and_nested_tags_are_never_accepted(self):
        release = Release(Path.cwd())
        with patch.object(release, "api", return_value={"object": {"type": "commit", "sha": "a" * 40}}):
            with self.assertRaisesRegex(ReleaseError, "annotated"):
                release.tag("0.3.0")
        with patch.object(release, "api", side_effect=[
            {"object": {"type": "tag", "sha": "a" * 40}},
            {"tag": "0.3.0", "object": {"type": "tag", "sha": "b" * 40}},
        ]):
            with self.assertRaisesRegex(ReleaseError, "directly"):
                release.tag("0.3.0")


if __name__ == "__main__":
    unittest.main()
