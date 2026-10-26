# Session contract fixtures

Recorded or specified mappings between a harness's native wire and the bridge v2
session contract (`inline_agent_bridge::harness`, spec §4.2). The contract test
(`tests/harness_fixtures.rs`) decodes every file here into contract types and
checks they re-encode to the same JSON, so a contract change that breaks a
fixture fails CI. Each driver also runs its own mapper over its provider's files.

## File shape

```json
{
  "provider": "claude",
  "harness": "claude-code 2.1.292",
  "recorded": false,
  "source": "where the native shapes come from",
  "description": "what the file covers",
  "deliveries": [{ "name": "...", "input": Input, "native": [frame, ...] }],
  "ops": [{ "name": "...", "op": Op, "native": [frame, ...] }],
  "steps": [{ "name": "...", "native": frame, "events": [Event, ...] }],
  "responses": [{ "name": "...", "interaction": "id", "decision_native": {...}?, "response": InteractionResponse, "native": frame }]
}
```

- `deliveries`: an `Input` and the frames the driver writes for it.
- `ops`: an `Op` and the frames the driver writes for it.
- `steps`: one native frame the harness sends, and the contract events the
  driver emits for it, in order. A step's events depend on earlier steps (the
  driver keeps item and turn state), so steps run in file order.
- `responses`: an answer to an interaction opened by an earlier step, and the
  frame the driver writes.
- The string `"<any>"` in a native frame matches any value (driver-generated
  request ids).
- `recorded: false` means the native frames are specified from the SDK types
  and lab notes, not yet captured from a live CLI. The harness-compatibility
  CI replaces them with recordings per version (spec §9).

## Claude conventions (for W2)

- Input ids are UUIDs: Claude's `uuid` must be one, and the contract echoes it.
- A Claude turn has no native id. The turn id is the `uuid` of the user message
  whose lifecycle opened the turn.
- Text and thinking items are `<message.id>:<content index>`; tool items use the
  `tool_use` id. Claude has no message phase; the final answer is the turn's
  last assistant text (`result.result`).
- Tool vocabulary: `Bash` → `command`; `Edit`/`Write`/`MultiEdit`/`NotebookEdit`
  → `file_change`; `TodoWrite` → `plan`; `Task`/`Agent` → `child`; everything
  else → `tool` with Claude's own name.
- Approval labels follow Claude Code's own prompt; W2 verifies the exact
  strings against the CLI and updates the fixtures.

Responses may also carry `after_step` (apply the answer right after that
step), `by` (the answering Inline user) and the `events` the answer emits.
