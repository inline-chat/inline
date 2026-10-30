# Inline Amp ACP patches

Source: `tao12345666333/amp-acp` at `e4ccce1b57c7ae92d75e8ba97fc03b92d414c06a`.

The embedded `dist/index.js` is built with Bun while keeping
`@agentclientprotocol/sdk` and `@ampcode/sdk` external. Inline adds `--no-ide`
to Amp's direct CLI transport. A managed background bridge has no IDE session,
and current Amp builds can otherwise block before producing stream output.

Equivalent source patch:

```diff
--- a/src/amp-transport.ts
+++ b/src/amp-transport.ts
@@
-  args.push('--execute', '--stream-json', '--no-archive-after-execute');
+  args.push('--execute', '--stream-json', '--no-archive-after-execute', '--no-ide');
```


## Inline continuity patch (`0.8.1+e4ccce1.inline2`)

The embedded artifact also adds bounded, private session records under the
bridge-owned `AMP_ACP_SESSION_DIR` and advertises ACP `loadSession` only when
that storage is configured. Records contain format version, canonical working
directory, exact native Amp thread ID, mode and model. They never contain MCP
commands/capabilities, prompts, or credentials. Writes use a private temporary
file, flush, and atomic rename; loads validate record shape and project.

`session/load` restores the exact thread and binds the newly supplied MCP
servers. The first native stream identity is saved before forwarding output.
The unsafe `AMP_ACP_CONTINUE_LATEST` fallback is removed: a new Inline chat
always starts a distinct Amp thread. Concurrent prompts in one session fail.
Older adapters remain on bridge v1 until explicit setup installs this pin.
The adapter no longer advertises inline image bytes that its prompt translator
ignores; Inline retains attachments as standard ACP file resource links.

After installing the pinned dependencies with scripts and optional packages
omitted, run `node --test continuity.test.mjs`. Set `INLINE_AMP_ADAPTER_BIN` to
exercise a scratch installation. The test drives actual ACP JSON-RPC across
adapter restarts using a fixture native CLI, including isolation, settings,
new MCP capabilities, wrong-project rejection, malformed records and cancel.
Live acceptance also requires the Rust `live_amp_v2` test and `acp_tools`
example against authenticated Amp, through Inline's process supervisor.
