# Apple package tests

Use the selected Xcode toolchain (`xcode-select -p`, `xcrun swift --version`).
The package lanes run on macOS; they do not need a simulator, app signing,
login credentials, or an unlocked developer Keychain.

```sh
scripts/apple/run-ci-checks.sh InlineKit InlineUI InlineIOSUI InlineMacUI
```

For a focused run, preserve the same dependency and execution settings:

```sh
xcrun swift test --package-path apple/InlineKit --disable-automatic-resolution --no-parallel --filter InlineSearchViewModelTests
xcrun swift build --package-path apple/InlineIOSUI --disable-automatic-resolution
```

Pass `--no-parallel` explicitly. Swift Testing otherwise starts independent
suites concurrently, despite SwiftPM's displayed default. Hundreds of database
migrations and main-actor fixtures can starve short polling deadlines. The CI
runner executes package lanes sequentially as well. Use parallel focused runs
to stress isolated fixtures, rather than relying on the whole UI suite to be
safe against shared AppKit services.

Builds default to two compiler jobs to avoid memory pressure on 8 GB machines.
Set `SWIFT_BUILD_JOBS` to a higher positive integer on larger CI hosts. Avoid
launching several cold package builds at once: each root builds its own copy
of the dependency graph.

Dependency changes require `swift package --package-path apple/<package> resolve`
for each affected root and review of its `Package.resolved`. Normal checks use
`--disable-automatic-resolution` so stale lockfiles fail instead of silently
selecting new versions. A first checkout may still download pinned dependencies
and binary artifacts; this is separate from test execution time.

## Isolation

- Inject `Auth.mocked(authenticated:)` or its handle. Pass explicit user IDs to
  query/projection helpers. Each auth fixture receives a unique namespace.
- Mock credential bytes live in a locked process-local store, never persistent
  preferences or Security.framework. Tests can reopen the same namespace to
  exercise recovery. Keychain status/fallback tests inject `KeychainClient`.
- Package test processes receive a logged-out shared auth fallback and an
  in-memory shared database. These protect legacy singleton consumers; new
  tests should inject their own database and authentication. The low-level
  Keychain wrapper traps before any read, write, or delete during tests.
- Use real in-memory GRDB writers for queries, transactions, migrations, and
  observations. Use a unique temporary directory when persistence is the subject
  of the test. Avoid application directories and shared preference keys.

## Async work and time

- Await the task or an explicit fixture event that proves the operation reached
  the required phase. A fixed sleep does not prove a request started or a stale
  result was processed. Search tests retain and await the actual task, including
  cancelled requests that deliberately finish late.
- Keep real timer tests focused on scheduling/cancellation. Test policy decisions
  with explicit times; do not wait seconds to exercise arithmetic or backoff rules.
- Where polling is necessary, use `ContinuousClock`, a bounded deadline, and an
  assertion on the observable result. A test timeout is a deadlock watchdog,
  not synchronization. Add suite time limits for fixtures that suspend on events.
- Model faults explicitly: hold a failure until the test releases it. A fake
  that fails exactly once can race an unrelated reconciliation or retry.
- Every suspended fake must have a teardown path that finishes its streams or
  resumes its continuations. Register before notifying waiters and buffer events
  so subscribing after an operation starts does not lose the notification.

Live CLI installer checks remain explicitly opt-in and are not part of the
headless package acceptance lane. Device, microphone, and real Keychain integration
checks are separate from these tests.
