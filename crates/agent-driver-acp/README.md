# Inline ACP Agent Driver

Stable Agent Client Protocol v1 support for Inline's local coding-agent bridge.

OpenCode, Claude Agent, and Amp are provider launch descriptors of this shared
driver rather than separate Rust packages. The driver
uses Inline's bounded patch of the official ACP Rust SDK, explicitly negotiates
stable protocol v1, normalizes streaming and permissions into Inline's
provider-neutral bridge contract, supports session resume/load and negotiated
model/reasoning configuration, maps bounded single- and multi-select ACP form
elicitation into Inline's existing question contract, and owns subprocess
shutdown through the SDK connection lifecycle. Only bounded choice fields and
Claude's marked optional custom-answer companions are accepted. Free-text
fields without a secret-aware contract and all other unsupported forms fail
closed; URL elicitation is not advertised.

Durable resume is enabled only when the pinned provider path passes live
cross-process evidence. OpenCode currently retains it. Claude's adapter
advertises resume but its current implementation can wedge that request, so
Inline rotates to a fresh Claude session after a provider epoch. Fresh ACP
sessions are created through one owned prewarm task because the Claude adapter
can acknowledge `session/new` before its first-prompt consumer is ready.

OpenCode uses its native `opencode acp` command. Claude uses an Inline-owned
complete dependency lock and exact npm adapter integrity pin. Amp uses an
Inline-owned, source-revision-pinned adapter bundle and complete dependency
lock; it launches the exact Amp CLI path accepted during setup through the
adapter's direct CLI transport. Adapter installation fails closed when its
manifest, lock, executable bytes, or integrity differs from the embedded pin.
The install omits and rejects the Amp SDK's optional native CLI packages so the
verified host executable cannot be shadowed by an adapter-local runtime.

Bridge-owned Inline tools use stable ACP v1's mandatory stdio MCP transport.
The agent launches the current Inline executable as a minimal MCP child. A
random per-session capability lets that child reach an epoch-local loopback
proxy, which maps calls to the active ACP session and turn before delegating to
the provider-neutral bridge tool handler. The child receives no Inline or bot
credential and the driver does not use ACP's unstable in-band MCP extension.

Run the hermetic conformance suite with:

```sh
cargo test -p inline-agent-driver-acp
```

An installed, authenticated OpenCode CLI can be exercised explicitly with:

```sh
cargo test -p inline-agent-driver-acp --test live_opencode -- --ignored --nocapture
```

The equivalent pinned Claude adapter smoke is opt-in and takes its executable
path explicitly:

```sh
INLINE_ACP_CLAUDE_BIN=/path/to/claude-agent-acp/dist/index.js \
  cargo test -p inline-agent-driver-acp --test live_claude -- --ignored --nocapture
```

An installed, authenticated Amp CLI and the installed Inline adapter can be
exercised through the production process host and Inline-tool handshake with:

```sh
INLINE_ACP_AMP_BIN=/path/to/installed/amp-agent-acp \
INLINE_ACP_AMP_CLI=/path/to/amp \
INLINE_ACP_PROCESS_HOST_BIN=/path/to/inline-agent-process-host \
INLINE_ACP_WITH_HOST_TOOLS=1 \
  cargo test -p inline-agent-driver-acp --test live_amp -- --ignored --nocapture
```
