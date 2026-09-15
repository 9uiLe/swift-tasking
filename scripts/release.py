#!/usr/bin/env python3
"""Prepare and publish owner-authenticated Swift package releases."""

import argparse
from dataclasses import dataclass
from datetime import date
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


OWNER = "9uiLe"
REPOSITORY = f"{OWNER}/swift-tasking"
BRANCH = "master"
WORKFLOW = ".github/workflows/ci.yml"
REQUIRED_JOBS = {"Swift package checks", "Release tooling checks"}
REMOTE = f"https://github.com/{REPOSITORY}.git"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
RELEASE_HEADING = re.compile(r"^## \[([0-9]+\.[0-9]+\.[0-9]+)\] - (\d{4}-\d{2}-\d{2})$", re.M)
INSTALLATION = re.compile(
    r'(\.package\(url: "https://github\.com/9uiLe/swift-tasking\.git", from: ")'
    r'([^"]+)("\))'
)


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def version_key(version):
    require(VERSION.fullmatch(version), "Use a stable version such as 0.3.0 (no v prefix or prerelease suffix).")
    return tuple(int(part) for part in version.split("."))


def release_notes(changelog, version):
    headings = list(RELEASE_HEADING.finditer(changelog))
    require(headings and headings[0].group(1) == version, f"The first CHANGELOG release must be {version}.")
    pending = changelog.split("## [Unreleased]\n")
    require(len(pending) == 2 and pending[1].split(headings[0].group(0), 1)[0].strip() == "",
            "Unreleased must be empty before publishing; prepare all pending changes first.")
    date.fromisoformat(headings[0].group(2))
    start = headings[0].end()
    end = headings[1].start() if len(headings) > 1 else len(changelog)
    notes = re.split(r"^\[[^\]]+\]:", changelog[start:end], maxsplit=1, flags=re.M)[0].strip()
    require(notes and re.search(r"^- \S", notes, re.M), "The release needs CHANGELOG entries.")
    return notes


def prepare_documents(changelog, readme, version, today):
    version_key(version)
    headings = list(RELEASE_HEADING.finditer(changelog))
    require(headings, "CHANGELOG needs a previous release heading.")
    previous = headings[0].group(1)
    require(version_key(version) > version_key(previous), "The version must be newer than the last CHANGELOG release.")
    require(changelog.count("## [Unreleased]\n") == 1, "CHANGELOG needs exactly one Unreleased section.")
    unreleased = changelog.index("## [Unreleased]\n")
    require(unreleased < headings[0].start(), "Unreleased must precede the released versions.")
    entries = changelog[unreleased + len("## [Unreleased]\n"):headings[0].start()].strip()
    require(re.search(r"^- \S", entries, re.M), "Unreleased has no release entries.")
    changelog = changelog.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{version}] - {today.isoformat()}\n", 1)
    link = f"[Unreleased]: https://github.com/{REPOSITORY}/compare/{previous}...HEAD"
    require(changelog.count(link) == 1, "The Unreleased comparison link must point to the previous version.")
    changelog = changelog.replace(link, f"[Unreleased]: https://github.com/{REPOSITORY}/compare/{version}...HEAD\n"
                                 f"[{version}]: https://github.com/{REPOSITORY}/compare/{previous}...{version}")
    require(len(INSTALLATION.findall(readme)) == 1, "README needs one versioned Tasking package dependency.")
    readme = INSTALLATION.sub(lambda match: match.group(1) + version + match.group(3), readme)
    return changelog, readme


def successful_run(runs, workflow_id, commit):
    matching = [run for run in runs if (
        run.get("workflow_id") == workflow_id
        and run.get("path") == WORKFLOW
        and run.get("event") == "push"
        and run.get("head_branch") == BRANCH
        and run.get("head_sha") == commit
        and run.get("head_repository", {}).get("full_name") == REPOSITORY
    )]
    require(matching, f"No master push CI run exists for {commit}. Wait for CI after merging the release PR.")
    run = max(matching, key=lambda item: (item["run_number"], item["run_attempt"]))
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            f"The latest CI run for {commit} has not succeeded: {run.get('html_url', '')}")
    return run


def validate_jobs(jobs, commit):
    for name in REQUIRED_JOBS:
        matching = [job for job in jobs if job.get("name") == name]
        require(len(matching) == 1 and matching[0].get("conclusion") == "success"
                and matching[0].get("head_sha") == commit,
                f"CI job {name!r} must succeed for the release commit.")


@dataclass(frozen=True)
class PublishPlan:
    version: str
    commit: str
    notes: str
    ci_url: str
    tag_exists: bool
    release: dict | None


class Release:
    def __init__(self, root):
        self.root = Path(root)

    def run(self, *arguments, input=None, allow_missing=False):
        environment = dict(os.environ, GH_HOST="github.com", GH_PROMPT_DISABLED="1", GIT_TERMINAL_PROMPT="0")
        result = subprocess.run(arguments, cwd=self.root, env=environment, input=input,
                                text=True, capture_output=True)
        if result.returncode:
            if allow_missing and "(HTTP 404)" in result.stderr:
                return None
            raise ReleaseError(result.stderr.strip() or result.stdout.strip() or f"{arguments[0]} failed")
        return result.stdout.strip()

    def git(self, *arguments):
        return self.run("git", *arguments)

    def api(self, path, *, method="GET", data=None, missing=False):
        arguments = ["gh", "api", "--hostname", "github.com", "--method", method, path]
        if data is not None:
            arguments.extend(["--input", "-"])
        output = self.run(*arguments, input=json.dumps(data) if data is not None else None, allow_missing=missing)
        return json.loads(output) if output else None

    def pages(self, path, field=None):
        items = []
        separator = "&" if "?" in path else "?"
        page = 1
        while True:
            response = self.api(f"{path}{separator}per_page=100&page={page}")
            batch = response[field] if field else response
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1

    def source(self, commit, path):
        return self.git("show", f"{commit}:{path}") + "\n"

    def authenticate(self):
        require(os.environ.get("GITHUB_ACTIONS") != "true", "Run releases locally with the owner's GitHub CLI authentication.")
        require(not self.git("status", "--porcelain"), "Commit or set aside working-tree changes before running release commands.")
        origin = self.git("remote", "get-url", "origin")
        require(origin in {REMOTE, REMOTE.removesuffix(".git"), f"git@github.com:{REPOSITORY}.git"},
                f"origin must be {REMOTE}.")
        user = self.api("user")
        require(user.get("login") == OWNER, f"Authenticate gh as {OWNER}; active user is {user.get('login')}.")
        repository = self.api(f"repos/{REPOSITORY}")
        require(repository.get("full_name") == REPOSITORY and repository.get("visibility") == "public"
                and repository.get("default_branch") == BRANCH and repository.get("permissions", {}).get("admin"),
                "The release repository must be public, use master, and grant the authenticated owner admin access.")
        self.git("-c", "credential.helper=", "-c", "credential.https://github.com.helper=!gh auth git-credential",
                 "fetch", REMOTE, f"refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}", "--tags")
        return self.git("rev-parse", f"origin/{BRANCH}")

    def tag(self, version):
        reference = self.api(f"repos/{REPOSITORY}/git/ref/tags/{version}", missing=True)
        if reference is None:
            return None
        require(reference["object"]["type"] == "tag", f"{version} must be an annotated tag; refusing to replace it.")
        tag = self.api(f"repos/{REPOSITORY}/git/tags/{reference['object']['sha']}")
        require(tag.get("tag") == version and tag["object"]["type"] == "commit", "The release tag must point directly to a commit.")
        return tag["object"]["sha"]

    def ensure_new_version(self, version):
        existing = self.pages(f"repos/{REPOSITORY}/tags")
        versions = [version_key(tag["name"]) for tag in existing
                    if VERSION.fullmatch(tag["name"]) and tag["name"] != version]
        require(not versions or version_key(version) > max(versions), "A newer or equal package version has already been tagged.")

    def find_release(self, version):
        # The tag endpoint omits drafts; the authenticated list includes them.
        matches = [release for release in self.pages(f"repos/{REPOSITORY}/releases")
                   if release.get("tag_name") == version]
        require(len(matches) <= 1, "Multiple Releases use this version; inspect them manually.")
        return matches[0] if matches else None

    def validate_release(self, release, version, commit, notes):
        require(release.get("tag_name") == version and release.get("target_commitish") == commit
                and release.get("author", {}).get("login") == OWNER
                and not release.get("prerelease") and not release.get("assets")
                and release.get("body", "").strip() == notes,
                "The existing Release differs from the owner, commit, notes, or source-only release plan; inspect it manually.")
        if not release.get("draft"):
            require(release.get("immutable") is True, "The published Release is not immutable; inspect its repository settings.")

    def plan(self, version):
        version_key(version)
        master = self.authenticate()
        immutable = self.api(f"repos/{REPOSITORY}/immutable-releases", missing=True)
        require(immutable and immutable.get("enabled"), "Enable Immutable releases in the repository before publishing.")
        tag_commit = self.tag(version)
        commit = tag_commit or master
        require(re.fullmatch(r"[0-9a-f]{40}", commit), "The release needs a full commit SHA.")
        require(self.git("merge-base", commit, master) == commit, "The tag commit is not on master.")
        notes = release_notes(self.source(commit, "CHANGELOG.md"), version)
        dependency = INSTALLATION.findall(self.source(commit, "README.md"))
        require(len(dependency) == 1 and dependency[0][1] == version, "README must install the release version.")
        release = self.find_release(version)
        if release:
            require(tag_commit, "A Release without the expected annotated tag needs manual inspection.")
            self.validate_release(release, version, commit, notes)
            if not release["draft"]:
                return PublishPlan(version, commit, notes, "Already published", True, release)
        self.ensure_new_version(version)
        workflow = self.api(f"repos/{REPOSITORY}/actions/workflows/ci.yml")
        require(workflow.get("path") == WORKFLOW and workflow.get("state") == "active", "The trusted CI workflow must be active.")
        runs = self.pages(f"repos/{REPOSITORY}/actions/workflows/{workflow['id']}/runs"
                          f"?branch={BRANCH}&event=push&head_sha={commit}", "workflow_runs")
        run = successful_run(runs, workflow["id"], commit)
        jobs = self.pages(f"repos/{REPOSITORY}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
        validate_jobs(jobs, commit)
        return PublishPlan(version, commit, notes, run["html_url"], bool(tag_commit), release)

    def publish(self, version):
        plan = self.plan(version)
        print(f"{REPOSITORY} {version} @ {plan.commit}\nCI: {plan.ci_url}", flush=True)
        if plan.release and not plan.release["draft"]:
            print(plan.release["html_url"])
            return
        current_tag = self.tag(version)
        require(current_tag is None or current_tag == plan.commit, "The remote tag changed during validation.")
        if current_tag is None:
            require(not plan.tag_exists, "The remote tag was deleted during validation.")
            current_master = self.api(f"repos/{REPOSITORY}/git/ref/heads/{BRANCH}")["object"]["sha"]
            require(current_master == plan.commit, "master changed during validation; run the command again.")
            tag = self.api(f"repos/{REPOSITORY}/git/tags", method="POST", data={
                "tag": version, "message": f"Release {version}", "object": plan.commit, "type": "commit",
            })
            self.api(f"repos/{REPOSITORY}/git/refs", method="POST", data={"ref": f"refs/tags/{version}", "sha": tag["sha"]})
        require(self.tag(version) == plan.commit, "The remote tag does not match the validated commit.")
        if not plan.release:
            with tempfile.TemporaryDirectory(prefix="tasking-release-") as temporary:
                notes = Path(temporary) / "notes.md"
                notes.write_text(plan.notes + "\n")
                self.run("gh", "release", "create", version, "--repo", REPOSITORY, "--verify-tag",
                         "--target", plan.commit, "--title", version, "--notes-file", str(notes), "--draft")
        draft = self.find_release(version)
        require(draft, "The draft Release was not found; run publish again to resume.")
        self.validate_release(draft, version, plan.commit, plan.notes)
        require(self.tag(version) == plan.commit, "The remote tag changed before publication.")
        if draft["draft"]:
            self.run("gh", "release", "edit", version, "--repo", REPOSITORY, "--draft=false", "--verify-tag", "--latest")
        published = self.find_release(version)
        require(published, "The published Release was not found; run publish again to inspect its state.")
        self.validate_release(published, version, plan.commit, plan.notes)
        require(not published["draft"], "The Release is still a draft; run publish again to resume.")
        require(self.tag(version) == plan.commit, "The published tag changed; inspect the release.")
        print(published["html_url"])

    def prepare(self, version, dry_run=False):
        version_key(version)
        master = self.authenticate()
        require(self.api(f"repos/{REPOSITORY}/git/ref/tags/{version}", missing=True) is None, "This version already has a tag.")
        require(self.find_release(version) is None, "This version already has a Release.")
        self.ensure_new_version(version)
        changelog, readme = prepare_documents(self.source(master, "CHANGELOG.md"), self.source(master, "README.md"), version, date.today())
        notes = release_notes(changelog, version)
        branch = f"release/{version}"
        require(not self.git("branch", "--list", branch), f"Local branch {branch} already exists; inspect the previous preparation.")
        require(self.api(f"repos/{REPOSITORY}/git/ref/heads/{branch}", missing=True) is None, f"Remote branch {branch} already exists.")
        print(f"Prepare {version} from {master}\n\n{notes}", flush=True)
        if dry_run:
            return
        self.git("switch", "-c", branch, master)
        (self.root / "CHANGELOG.md").write_text(changelog)
        (self.root / "README.md").write_text(readme)
        self.git("add", "--", "CHANGELOG.md", "README.md")
        self.git("commit", "-m", f"Prepare {version} release", "-m",
                 "Consumers need a versioned package snapshot with its compatibility contract and release notes.")
        self.git("-c", "credential.helper=", "-c", "credential.https://github.com.helper=!gh auth git-credential",
                 "push", REMOTE, f"HEAD:refs/heads/{branch}")
        body = f"## Summary\n\nPrepare Tasking {version}.\n\n{notes}\n\n## Validation\n\nCI must pass before merging. Publishing also requires CI for the merged master commit.\n"
        with tempfile.TemporaryDirectory(prefix="tasking-release-") as temporary:
            path = Path(temporary) / "pr.md"
            path.write_text(body)
            url = self.run("gh", "pr", "create", "--repo", REPOSITORY, "--base", BRANCH, "--head", branch,
                           "--title", f"Prepare {version} release", "--body-file", str(path))
        print(url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("prepare", "check", "publish"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("version")
        if command == "prepare":
            subparser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    release = Release(Path(__file__).resolve().parents[1])
    try:
        if arguments.command == "prepare":
            release.prepare(arguments.version, arguments.dry_run)
        elif arguments.command == "check":
            plan = release.plan(arguments.version)
            print(f"Ready: {REPOSITORY} {plan.version} @ {plan.commit}\nCI: {plan.ci_url}\n\n{plan.notes}")
        else:
            release.publish(arguments.version)
    except (ReleaseError, OSError, ValueError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
