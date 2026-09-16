# Contributing

[日本語](CONTRIBUTING.md) | English

Tasking makes ownership and execution policy explicit for unstructured tasks.
Contributions should preserve readable public contracts, coherent responsibilities,
and reliable cancellation and completion waits. The code is available under the
[MIT License](LICENSE).

## Understand the design and contracts

Read [purpose and principles](docs/positioning.md), the [glossary](docs/glossary.md),
and the [architecture](docs/architecture.md) to identify the affected responsibility
and public contract. The [decision index](docs/README.md#設計判断adr) links to design
rationale. These design documents are maintained in Japanese.

| Information | Where it belongs |
|---|---|
| How behavior is implemented | Code names, types, control flow, and module boundaries |
| Observable behavior | Public API documentation comments and tests |
| Durable design rationale | `docs/adr/` |
| Problems, motivation, and context specific to one change | Commit messages |
| Constraints or reasons to reject alternatives that code cannot express | Implementation comments |

Update documentation, tests, and rationale together when changing a contract.
Prefer clearer names and structure over comments that narrate implementation.
See [repository guidance](AGENTS.md) for the full conventions.

## Validate changes

Keep compatibility with Swift tools 6.0 and use Swift 6 language mode. Run the
following from the repository root to validate both the library and prototype:

```sh
for tasking_package in . Examples/TaskingPrototype; do
  swift build --package-path "$tasking_package" -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  swift test --package-path "$tasking_package" -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  swift test --package-path "$tasking_package" -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  swift test --package-path "$tasking_package" --sanitize=thread -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
done
```

Use Xcode for the iOS Simulator build:

```sh
xcodebuild build -quiet -scheme swift-tasking-Package \
  -destination 'generic/platform=iOS Simulator'
```

Test through public interfaces. Use operation gates to control arrival and
resumption, and completion APIs to establish termination. Do not infer completion
from tracking queries, short sleeps, or private storage. See the
[testing guidance](docs/architecture.md#テスト方針) for observation points.

Measure performance with the independent Release [benchmark](Benchmarks/README.md).
Report workloads, toolchain, source identity, and variation. Keep absolute timing
thresholds out of correctness tests.

## Write documentation and examples

Japanese is the primary language for documents, public API comments, implementation
comments, commit messages, and pull requests. Keep code identifiers, protocol fields,
command names, and stable CI check names in their established form. Preserve the
original MIT license text.

README, this guide, and the security policy have Japanese sources and English
`.en.md` editions; update each pair together. Design documents, ADRs, the changelog,
and operating guides are maintained in Japanese. Both READMEs must describe the
same API, examples, requirements, and installation version.

Organize explanations around purpose, prerequisites, and the current contract.
Examples must identify imports, execution context, OS requirements, and dependencies
provided by the application. Keep cancellation and error handling consistent with
public contracts, and verify relative links and code examples.

## Record release-facing changes

Write user-facing changes in Japanese under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md). Include required action for breaking changes. Entries
also become the GitHub Release body, so use full URLs. Preserve the machine-readable
format of `[Unreleased]` and version headings.

Release tooling tests require Python 3.10+:

```sh
python3 -m unittest discover -s scripts/tests -v
```

Temporary Git repositories and simulated GitHub responses cover updating both
READMEs, rejecting inconsistent documents, publishing, and resuming. CI runs
`Release tooling checks` and `Swift package checks` on PRs and master pushes.

The owner's `prepare` command updates release notes and both README dependency
versions, then creates a preparation PR. Publication requires both CI jobs to
succeed for the merged release commit. See the [release guide](docs/releasing.md)
for procedures and recovery.
