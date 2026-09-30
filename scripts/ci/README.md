# CI validation

`Apple validation required`, `Integrations required`, and `Server validation required`
are stable aggregate checks. They fail when any selected dependency fails, is
cancelled, or is unexpectedly skipped. Their dependency inventories are tested
against the workflow YAML. Configure these as required checks **after this PR is
merged and each has completed on main**; path-filtered CLI jobs are unsuitable
as universal required checks.

Apple runs all five lanes on main and manual dispatches. On PRs, only changes
entirely within known unrelated directories may skip the Apple lanes. Changes to
Apple, canonical protocol and trust roots, scripts, workflows, root JS manifests, unknown paths, or unavailable
diffs select all five. The selector writes its decision to the Actions summary.

Rust workspace CI owns formatting, all-target compilation, tests, and Clippy. CLI
Build adds AMD64/ARM64 musl executable and installer checks. Server Tests owns the
TypeScript protocol drift check; the previous duplicate workflows are preserved
under `.github/disabled-workflows`.

The assembled integration lane verifies all candidate hashes and the source SHA.
It tests Bot HTTP message bodies, SDK recipient WebSocket delivery, idempotent
sends, history on a new connection, Chat SDK real-update dispatch and persisted
replies, duplicate webhook delivery, webhook authentication, compiled MCP
send/history, MCP grant revocation, and the existing real Hermes host round trip.
Scenario receipts and the candidate manifest are retained for seven days. OAuth
introspection is synthetic and Chat SDK webhook delivery is driven by the fixture;
this does not qualify the production OAuth issuer or webhook worker.

Hermes and OpenClaw scheduled compatibility checks exercise published packages
against moving hosts independently of source changes. OpenClaw admission proves
installation and registration; an actual OpenClaw host message handler against
Inline remains a separate qualification gap.

Native app builds and Swift package tests do not establish UI acceptance. Shared
scheme references are checked for missing targets. `Inline Message Tests` remains
the existing iOS device test scheme; no app UI test targets currently exist.
Before accepting a native release, use a physical iOS device and the macOS app to
check sign-in, send/reply, reconnect, logout only after explicit token revocation,
and correct message identity after optimistic-to-confirmed reconciliation. Record
the build SHA and test outcome. Do not substitute simulator or unsigned build
success for this acceptance.

MCP's existing 95% line/function coverage thresholds remain unchanged. They are
currently unmet; enabling coverage as a merge gate requires further focused tests,
especially remote-file transport branches. The regular suite now also verifies
every v2 tool's missing-scope boundary and failed-send reporting.
