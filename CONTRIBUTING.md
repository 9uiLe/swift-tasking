# Contributing

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

Write the README and public API documentation comments in English. Write design
documents and ADRs in Japanese, using the [glossary](docs/glossary.md).
Describe the complete contract so a reader needs no conversation history.

Check relative links and the availability requirements of Swift snippets. Examples
must identify application-provided dependencies and demonstrate cancellation and
error handling consistent with the public contract. Record release-facing API
changes in [CHANGELOG.md](CHANGELOG.md).
