# Contributing

[日本語](CONTRIBUTING.md) | English

Tasking is a reference implementation for explicit ownership of unstructured Swift
Concurrency tasks. Design consistency, readable contracts, and reliable cancellation
and completion behavior guide contributions. The code is available under the
[MIT License](LICENSE), including for incorporation into other codebases.

## Understand the design

Start with the [documentation guide](docs/README.md) and
[architecture](docs/architecture.md). Design decisions live in `docs/adr/`.
A proposal that changes a documented contract should update its rationale and the
public behavior tests together.

Production code explains how behavior works. Tests specify observable behavior.
ADRs hold durable design rationale; commit messages hold the motivation specific to
an individual change. Implementation comments preserve constraints or explain why
an apparent alternative is unsafe. See [repository guidance](AGENTS.md).

## Validate changes

Use the Swift 6 language mode and the package's Swift tools 6.0 compatibility floor.
Keep strict concurrency checks free of warnings. CI runs these commands for both
the root package and `Examples/TaskingPrototype`:

```sh
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --sanitize=thread -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

The root package also builds for iOS Simulator:

```sh
xcodebuild build -quiet -scheme swift-tasking-Package \
  -destination 'generic/platform=iOS Simulator'
```

Test through public interfaces. Use operation gates and completion APIs to control
ordering; do not infer completion from tracking queries, scheduler delays, or private
storage. The [testing guidance](docs/architecture.md#テスト方針) explains the observation points.

Performance measurements belong in the independent Release
[benchmark package](Benchmarks/README.md). Report workload, toolchain, source identity,
and variation. Keep absolute timing thresholds out of correctness tests.

## Documentation and examples

Japanese is the primary language for documentation, API comments, implementation
comments, commit messages, and pull requests. Use the [glossary](docs/glossary.md).
Keep code identifiers, protocol fields, command names, and stable CI check names in
their established form. The MIT license retains its original text.

English editions are provided for README, this contribution guide, and the security
policy. Update each translation with its Japanese source when its content changes;
do not duplicate every design document. Both READMEs must describe the same API,
examples, requirements, and installation version. Describe complete contracts so
readers need no conversation history.

Check relative links and the availability requirements of Swift snippets. Examples
must identify application-provided dependencies and demonstrate cancellation and
error handling consistent with the public contract. Record release-facing API
changes in [CHANGELOG.md](CHANGELOG.md).

## Release tooling

Python 3.10+ tests exercise preparation, validation, and publication with temporary
Git repositories and simulated GitHub responses:

```sh
python3 -m unittest discover -s scripts/tests -v
```

CI runs `Release tooling checks` alongside `Swift package checks` on pull requests
and master pushes. Publication requires both jobs to succeed for the exact master
commit being released. Actions uses read-only permissions; the owner publishes
locally with GitHub CLI authentication.

Write user-facing entries in Japanese under `## [Unreleased]` in CHANGELOG.md.
Keep the `[Unreleased]` and version headings in their machine-readable format.
Use full URLs in release entries because they become the GitHub Release body. The owner's `prepare`
command moves those entries into a dated release section, updates the Japanese and English README
dependencies and comparison links, and opens a preparation PR.
See the [release guide](docs/releasing.md) for commands and recovery procedures.
