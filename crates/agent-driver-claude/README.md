# Inline Claude Driver

Rust-native driver for Claude Code in Inline's local coding-agent bridge.

The bridge spawns the user's installed `claude` with
`--output-format stream-json --input-format stream-json --verbose
--permission-prompt-tool stdio`, an explicit `--permission-mode`, and
`--session-id` or `--resume`, then speaks Claude Code's control protocol
directly. Nothing is bundled: no Node, no Bun, no copy of Claude Code.

- Control requests both ways: initialize, interrupt (with `cancel_queued`),
  model, permission mode, context usage, MCP status/toggle/reconnect, file
  rewind and task stop out; permission asks (approvals and AskUserQuestion),
  hook callbacks, in-process MCP and cancellation in.
- User messages carry `uuid`, `priority` (`now` / `next` / `later`),
  `shouldQuery` and `origin`.
- Every stdout frame keeps its native JSON; unknown kinds are passed through.

The MIT Python Agent SDK (`claude-agent-sdk`) is the readable reference for
the port; the TypeScript SDK's `sdk.d.ts` is the coverage checklist.
