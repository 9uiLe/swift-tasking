#!/usr/bin/env python3
"""所有者の認証で Swift package のリリースを準備・公開する。"""

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
README_PATHS = ("README.md", "README.en.md")
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
    require(VERSION.fullmatch(version), "0.3.0 のような安定版番号を指定してください（v 接頭辞やプレリリース接尾辞は不要です）。")
    return tuple(int(part) for part in version.split("."))


def release_notes(changelog, version):
    headings = list(RELEASE_HEADING.finditer(changelog))
    require(headings and headings[0].group(1) == version, f"CHANGELOG の最新リリースは {version} にしてください。")
    pending = changelog.split("## [Unreleased]\n")
    require(len(pending) == 2 and pending[1].split(headings[0].group(0), 1)[0].strip() == "",
            "公開前に Unreleased を空にしてください。未公開の変更をすべて準備する必要があります。")
    date.fromisoformat(headings[0].group(2))
    start = headings[0].end()
    end = headings[1].start() if len(headings) > 1 else len(changelog)
    notes = re.split(r"^\[[^\]]+\]:", changelog[start:end], maxsplit=1, flags=re.M)[0].strip()
    require(notes and re.search(r"^- \S", notes, re.M), "CHANGELOG にリリース項目が必要です。")
    return notes


def validate_readmes(readmes, version):
    for path in README_PATHS:
        require(path in readmes, f"{path} が必要です。")
        dependencies = INSTALLATION.findall(readmes[path])
        require(len(dependencies) == 1, f"{path} には Tasking のバージョン付き依存指定が1つ必要です。")
        require(dependencies[0][1] == version, f"{path} の依存バージョンは {version} に揃えてください。")


def prepare_documents(changelog, readmes, version, today):
    version_key(version)
    headings = list(RELEASE_HEADING.finditer(changelog))
    require(headings, "CHANGELOG に前回のリリース見出しが必要です。")
    previous = headings[0].group(1)
    validate_readmes(readmes, previous)
    require(version_key(version) > version_key(previous), "CHANGELOG の最新リリースより新しい番号を指定してください。")
    require(changelog.count("## [Unreleased]\n") == 1, "CHANGELOG には Unreleased 節が1つ必要です。")
    unreleased = changelog.index("## [Unreleased]\n")
    require(unreleased < headings[0].start(), "Unreleased は公開済みのバージョンより前に配置してください。")
    entries = changelog[unreleased + len("## [Unreleased]\n"):headings[0].start()].strip()
    require(re.search(r"^- \S", entries, re.M), "Unreleased にリリース項目がありません。")
    changelog = changelog.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{version}] - {today.isoformat()}\n", 1)
    link = f"[Unreleased]: https://github.com/{REPOSITORY}/compare/{previous}...HEAD"
    require(changelog.count(link) == 1, "Unreleased の比較リンクは前回のバージョンを起点にしてください。")
    changelog = changelog.replace(link, f"[Unreleased]: https://github.com/{REPOSITORY}/compare/{version}...HEAD\n"
                                 f"[{version}]: https://github.com/{REPOSITORY}/compare/{previous}...{version}")
    readmes = {path: INSTALLATION.sub(lambda match: match.group(1) + version + match.group(3), readmes[path])
               for path in README_PATHS}
    return changelog, readmes


def successful_run(runs, workflow_id, commit):
    matching = [run for run in runs if (
        run.get("workflow_id") == workflow_id
        and run.get("path") == WORKFLOW
        and run.get("event") == "push"
        and run.get("head_branch") == BRANCH
        and run.get("head_sha") == commit
        and run.get("head_repository", {}).get("full_name") == REPOSITORY
    )]
    require(matching, f"{commit} の master push CI がありません。リリース PR のマージ後に CI の完了を待ってください。")
    run = max(matching, key=lambda item: (item["run_number"], item["run_attempt"]))
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            f"{commit} の最新 CI が成功していません: {run.get('html_url', '')}")
    return run


def validate_jobs(jobs, commit):
    for name in REQUIRED_JOBS:
        matching = [job for job in jobs if job.get("name") == name]
        require(len(matching) == 1 and matching[0].get("conclusion") == "success"
                and matching[0].get("head_sha") == commit,
                f"リリース対象のコミットで CI ジョブ {name!r} が成功している必要があります。")


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
                                text=True, encoding="utf-8", capture_output=True)
        if result.returncode:
            if allow_missing and "(HTTP 404)" in result.stderr:
                return None
            raise ReleaseError(result.stderr.strip() or result.stdout.strip() or f"{arguments[0]} が失敗しました")
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
        require(os.environ.get("GITHUB_ACTIONS") != "true", "所有者の GitHub CLI 認証を使い、ローカルでリリースを実行してください。")
        require(not self.git("status", "--porcelain"), "リリースコマンドの前に作業ツリーの変更をコミットするか退避してください。")
        origin = self.git("remote", "get-url", "origin")
        require(origin in {REMOTE, REMOTE.removesuffix(".git"), f"git@github.com:{REPOSITORY}.git"},
                f"origin は {REMOTE} に設定してください。")
        user = self.api("user")
        require(user.get("login") == OWNER, f"{OWNER} として gh を認証してください。現在のユーザーは {user.get('login')} です。")
        repository = self.api(f"repos/{REPOSITORY}")
        require(repository.get("full_name") == REPOSITORY and repository.get("visibility") == "public"
                and repository.get("default_branch") == BRANCH and repository.get("permissions", {}).get("admin"),
                "公開リポジトリで、既定ブランチが master、認証した所有者に管理者権限があることが必要です。")
        self.git("-c", "credential.helper=", "-c", "credential.https://github.com.helper=!gh auth git-credential",
                 "fetch", REMOTE, f"refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}", "--tags")
        return self.git("rev-parse", f"origin/{BRANCH}")

    def tag(self, version):
        reference = self.api(f"repos/{REPOSITORY}/git/ref/tags/{version}", missing=True)
        if reference is None:
            return None
        require(reference["object"]["type"] == "tag", f"{version} には注釈付きタグが必要です。既存のタグは置き換えません。")
        tag = self.api(f"repos/{REPOSITORY}/git/tags/{reference['object']['sha']}")
        require(tag.get("tag") == version and tag["object"]["type"] == "commit", "リリースタグはコミットを直接指す必要があります。")
        return tag["object"]["sha"]

    def ensure_new_version(self, version):
        existing = self.pages(f"repos/{REPOSITORY}/tags")
        versions = [version_key(tag["name"]) for tag in existing
                    if VERSION.fullmatch(tag["name"]) and tag["name"] != version]
        require(not versions or version_key(version) > max(versions), "同じか新しい package バージョンのタグが既にあります。")

    def find_release(self, version):
        # タグ指定の API はドラフトを返さないため、認証付きの一覧 API を使う。
        matches = [release for release in self.pages(f"repos/{REPOSITORY}/releases")
                   if release.get("tag_name") == version]
        require(len(matches) <= 1, "このバージョンに複数の Release があります。手動で確認してください。")
        return matches[0] if matches else None

    def validate_release(self, release, version, commit, notes):
        require(release.get("tag_name") == version and release.get("target_commitish") == commit
                and release.get("author", {}).get("login") == OWNER
                and not release.get("prerelease") and not release.get("assets")
                and release.get("body", "").strip() == notes,
                "既存の Release の所有者・コミット・ノート・添付ファイルが、ソースのみの公開計画と一致しません。手動で確認してください。")
        if not release.get("draft"):
            require(release.get("immutable") is True, "公開済みの Release が immutable ではありません。リポジトリ設定を確認してください。")

    def plan(self, version):
        version_key(version)
        master = self.authenticate()
        immutable = self.api(f"repos/{REPOSITORY}/immutable-releases", missing=True)
        require(immutable and immutable.get("enabled"), "公開前にリポジトリの Immutable releases を有効にしてください。")
        tag_commit = self.tag(version)
        commit = tag_commit or master
        require(re.fullmatch(r"[0-9a-f]{40}", commit), "リリースには完全なコミット SHA が必要です。")
        require(self.git("merge-base", commit, master) == commit, "タグのコミットが master の履歴にありません。")
        notes = release_notes(self.source(commit, "CHANGELOG.md"), version)
        validate_readmes({path: self.source(commit, path) for path in README_PATHS}, version)
        release = self.find_release(version)
        if release:
            require(tag_commit, "対応する注釈付きタグのない Release があります。手動で確認してください。")
            self.validate_release(release, version, commit, notes)
            if not release["draft"]:
                return PublishPlan(version, commit, notes, "公開済み", True, release)
        self.ensure_new_version(version)
        workflow = self.api(f"repos/{REPOSITORY}/actions/workflows/ci.yml")
        require(workflow.get("path") == WORKFLOW and workflow.get("state") == "active", "検証対象の CI ワークフローが有効である必要があります。")
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
        require(current_tag is None or current_tag == plan.commit, "検証中にリモートタグが変更されました。")
        if current_tag is None:
            require(not plan.tag_exists, "検証中にリモートタグが削除されました。")
            current_master = self.api(f"repos/{REPOSITORY}/git/ref/heads/{BRANCH}")["object"]["sha"]
            require(current_master == plan.commit, "検証中に master が変更されました。コマンドを再実行してください。")
            tag = self.api(f"repos/{REPOSITORY}/git/tags", method="POST", data={
                "tag": version, "message": f"{version} のリリース", "object": plan.commit, "type": "commit",
            })
            self.api(f"repos/{REPOSITORY}/git/refs", method="POST", data={"ref": f"refs/tags/{version}", "sha": tag["sha"]})
        require(self.tag(version) == plan.commit, "リモートタグが検証済みのコミットと一致しません。")
        if not plan.release:
            with tempfile.TemporaryDirectory(prefix="tasking-release-") as temporary:
                notes = Path(temporary) / "notes.md"
                notes.write_text(plan.notes + "\n", encoding="utf-8")
                self.run("gh", "release", "create", version, "--repo", REPOSITORY, "--verify-tag",
                         "--target", plan.commit, "--title", version, "--notes-file", str(notes), "--draft")
        draft = self.find_release(version)
        require(draft, "ドラフトの Release が見つかりません。publish を再実行して再開してください。")
        self.validate_release(draft, version, plan.commit, plan.notes)
        require(self.tag(version) == plan.commit, "公開前にリモートタグが変更されました。")
        if draft["draft"]:
            self.run("gh", "release", "edit", version, "--repo", REPOSITORY, "--draft=false", "--verify-tag", "--latest")
        published = self.find_release(version)
        require(published, "公開済みの Release が見つかりません。publish を再実行して状態を確認してください。")
        self.validate_release(published, version, plan.commit, plan.notes)
        require(not published["draft"], "Release がまだドラフトです。publish を再実行して再開してください。")
        require(self.tag(version) == plan.commit, "公開済みタグが変更されました。リリースを確認してください。")
        print(published["html_url"])

    def prepare(self, version, dry_run=False):
        version_key(version)
        master = self.authenticate()
        require(self.api(f"repos/{REPOSITORY}/git/ref/tags/{version}", missing=True) is None, "このバージョンのタグは既にあります。")
        require(self.find_release(version) is None, "このバージョンの Release は既にあります。")
        self.ensure_new_version(version)
        changelog, readmes = prepare_documents(self.source(master, "CHANGELOG.md"),
                                              {path: self.source(master, path) for path in README_PATHS},
                                              version, date.today())
        notes = release_notes(changelog, version)
        branch = f"release/{version}"
        require(not self.git("branch", "--list", branch), f"ローカルブランチ {branch} は既に存在します。準備済みの内容を確認してください。")
        require(self.api(f"repos/{REPOSITORY}/git/ref/heads/{branch}", missing=True) is None, f"リモートブランチ {branch} は既に存在します。")
        print(f"{master} から {version} を準備します\n\n{notes}", flush=True)
        if dry_run:
            return
        self.git("switch", "-c", branch, master)
        (self.root / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
        for path, content in readmes.items():
            (self.root / path).write_text(content, encoding="utf-8")
        self.git("add", "--", "CHANGELOG.md", *README_PATHS)
        self.git("commit", "-m", f"{version} のリリースを準備", "-m",
                 "利用者がバージョン付きのソースと互換性の契約・リリースノートを参照できるよう、両言語の導入手順と変更履歴を揃える。")
        self.git("-c", "credential.helper=", "-c", "credential.https://github.com.helper=!gh auth git-credential",
                 "push", REMOTE, f"HEAD:refs/heads/{branch}")
        body = f"## 概要\n\nTasking {version} のリリースを準備します。\n\n{notes}\n\n## 検証\n\nマージ前に CI の成功を確認してください。公開にはマージ後の master コミットの CI 成功も必要です。\n"
        with tempfile.TemporaryDirectory(prefix="tasking-release-") as temporary:
            path = Path(temporary) / "pr.md"
            path.write_text(body, encoding="utf-8")
            url = self.run("gh", "pr", "create", "--repo", REPOSITORY, "--base", BRANCH, "--head", branch,
                           "--title", f"{version} のリリースを準備", "--body-file", str(path))
        print(url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command, description in (
        ("prepare", "文書を更新してリリース準備 PR を作成する"),
        ("check", "ソース・文書・CI の公開条件を確認する"),
        ("publish", "検証済みコミットのタグと GitHub Release を公開する"),
    ):
        subparser = subparsers.add_parser(command, help=description, description=description)
        subparser.add_argument("version", help="X.Y.Z 形式の安定版番号")
        if command == "prepare":
            subparser.add_argument("--dry-run", action="store_true", help="ファイル変更やリモート書き込みを行わず準備内容を表示する")
    arguments = parser.parse_args()
    release = Release(Path(__file__).resolve().parents[1])
    try:
        if arguments.command == "prepare":
            release.prepare(arguments.version, arguments.dry_run)
        elif arguments.command == "check":
            plan = release.plan(arguments.version)
            print(f"公開条件を確認済み: {REPOSITORY} {plan.version} @ {plan.commit}\nCI: {plan.ci_url}\n\n{plan.notes}")
        else:
            release.publish(arguments.version)
    except (ReleaseError, OSError, ValueError) as error:
        print(f"リリース処理を停止しました: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
