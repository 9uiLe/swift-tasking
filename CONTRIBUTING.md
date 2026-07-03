# Contributing

Thanks for your interest in Tasking.

## Project stance

This library is published primarily as a **reference implementation of a design
idea**: giving unstructured Swift Concurrency tasks an explicit vocabulary for
ownership, lifetime, and duplicate policy. Copying the code into your own
codebase is a welcome outcome.

Because of that goal, design consistency is prioritized over feature growth:

- Design rationale lives in [`docs/`](docs/README.md). The ADRs are the source
  of truth — proposals that conflict with an accepted ADR should argue against
  the ADR first, not the code.
- Feature requests are weighed against the principle *"make it visible, don't
  take it over"* and may be declined to keep the surface minimal. Planned
  extensions are listed in the [0.2 roadmap](docs/adoption.md#02-系ロードマップ候補).
- Bug reports with a failing test are the fastest path to a fix.

## Pull requests

- Keep Swift 6 strict concurrency builds warning-free.
- `swift test` must pass for the root package and for
  `Examples/TaskingPrototype` (debug, release, and `--sanitize=thread`) — CI
  enforces this.
- Mind toolchain compatibility: CI runs an older Xcode than the latest; avoid
  syntax that requires the newest Swift compiler unless the package floor moves.
- API doc comments are written in English; design docs under `docs/` are
  written in Japanese (see ADR-0008).

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
