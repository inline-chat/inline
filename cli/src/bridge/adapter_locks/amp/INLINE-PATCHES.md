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


## Inline continuity patch (`0.8.1+e4ccce1.inline3`)

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

The current Amp CLI emits `shell_command` and `create_file` tools. Inline maps
these to ACP execute/edit activity with their real command or file location;
file contents are not progress previews. Status-only updates retain the bounded,
sanitized command preview, and absent arguments do not produce placeholder
command lines or empty `details` objects. Generic tools can retain a bounded
identifier without their provider-rendered argument suffix.

Assistant text drops only the exact `<suggested-replies>` and
`</suggested-replies>` wrapper tags, retaining their reply text as Markdown.
The filter handles tags split across native text blocks and flushes incomplete
tag prefixes unchanged. Real tool failures and their diagnostics remain visible.

After installing the pinned dependencies with scripts and optional packages
omitted, run `node --test continuity.test.mjs`. Set `INLINE_AMP_ADAPTER_BIN` to
exercise a scratch installation. The test drives actual ACP JSON-RPC across
adapter restarts using a fixture native CLI, including isolation, settings,
new MCP capabilities, wrong-project rejection, malformed records and cancel.
It also emits the real Amp tool shapes through the CLI transport and checks
ACP kinds/arguments, failed results, and split suggested-reply wrappers.
Live acceptance also requires the Rust `live_amp_v2` test and `acp_tools`
example against authenticated Amp, through Inline's process supervisor.

The durable load path re-advertises the same `/init` command as new sessions.
The continuity regression also sends `/init` as its own text block with separate
assistant context, checking that command expansion and Inline's guide both reach
the native prompt after ACP translation.
