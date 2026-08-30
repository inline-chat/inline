# CLI diagnostics and error reporting

To diagnose agent setup, repeat the original command with `--verbose`. Repeat
the flag for trace-level detail:

```sh
inline agents setup --target codex --verbose
inline agents setup --target codex --verbose --verbose
inline --json --compact agents setup --target codex --verbose --verbose 2>inline-setup.log
```

`-v` continues to print the version. Diagnostics go to stderr; JSON results and
app-protocol progress stay on stdout. Verbose stderr can contain diagnostic lines
before the terminal JSON error. Without `--verbose`, JSON errors remain a single
document. Native hosts should decode the terminal compact error line.

Logs include setup phases, elapsed times, subprocess exit status, scrubbed stderr,
and underlying error causes. Output retention is bounded. Credentials, signed URL
parameters, terminal controls, and local paths are scrubbed from diagnostic text.
HTTP wire logging and arbitrary dependency logs are not enabled, including by
`RUST_LOG`. Redaction cannot recognize every possible secret: review local logs
before sharing them. Do not share auth/config files or environment dumps.

On failure, keep the error code, failed phase, completed changes, CLI version,
OS, and approximate time. Retry commands preserve the original setup options;
there is no automatic retry of bot creation or other mutating steps. A successful
setup health check does not prove a generated first reply.

OpenClaw setup stops if its gateway returns config-only or unreadable status:
repair/start the gateway before retrying, so an unavailable identity probe cannot
create a replacement bot. Setup manages the literal default Inline account;
named default accounts require direct OpenClaw configuration or a separate profile.
Service installation is selected from the explicit service state, not command exit status.

Hermes setup verifies the optional `gateway` field in the Inline adapter's status
output, including a changed process generation after restart and matching platform
writer identity. Older installed adapters/hosts stop in preflight with
`gateway_readiness_unverified`; update Hermes and the Inline adapter before retrying.
An older host with no runtime record may only reveal missing writer metadata after
startup. `--no-restart` intentionally leaves readiness unverified. These changes
require coordinated CLI and Hermes adapter releases and current-host validation.

## Optional Sentry reporting

Reporting is disabled when no DSN is configured. `INLINE_CLI_SENTRY_DSN` can be
provided to the build to embed the CLI project's public DSN, or set at runtime.
An empty runtime value disables an embedded DSN. No DSN is included in source.
The native app strips runtime Inline environment overrides, so distributed app
setup should use the CLI's embedded DSN when reporting is enabled.

Set `INLINE_CLI_TELEMETRY=off` (or `0` or `false`, case-insensitive) to disable reporting. Help/version and
argument parsing do not initialize Sentry. Invalid DSNs disable reporting without
breaking the command; the warning is visible only with verbose diagnostics.
Exit waits at most two seconds for reporting, including SDK transport teardown.
A stalled upload may be abandoned when the CLI exits.

Only command failures are sent, with release, OS/architecture, error code, setup
provider, and setup phase when available, plus an event timestamp and generated
identifier. No raw error messages, argv, environment,
local logs, usernames, bot IDs, paths, request bodies, stack traces, breadcrumbs,
or session/usage tracking are sent. The codes `invalid_args`, `not_authenticated`,
`setup_cancelled`, and `confirmation_required` are excluded. Other validation
errors may be reported. Runtime bridge errors that are recovered internally and
panics are not captured in this first slice. Expected doctor/health results that
print their own status are also excluded.

The SDK's default integrations are disabled. The final event hook reconstructs
the payload from the metadata allowlist, so future scope additions cannot upload
arbitrary context. This is deliberately more restrictive than the SDK defaults.
See the [official Rust SDK options](https://docs.rs/sentry/latest/sentry/struct.ClientOptions.html).

Local process tests inspect the actual HTTP envelope and verify that opt-out,
an empty DSN, help/version, completions, and excluded errors make no connection.
They also cover invalid DSNs and an endpoint that accepts a request but never
responds. These fixtures use synthetic data and do not prove project ingestion.

Before enabling a distributed DSN, validate one synthetic failure's ingestion,
inspect its event payload, verify opt-out and offline behavior, and update the
release's privacy disclosure. Never send real credentials as a test fixture.
