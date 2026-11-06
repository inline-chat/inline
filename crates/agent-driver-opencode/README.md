# Inline OpenCode Agent Driver

Native integration with OpenCode v2 for Inline's local coding-agent bridge.
OpenCode v2 runs one background service per user that every client shares
(TUI, desktop, web). This driver is one more client of that service: it
speaks the HTTP API, follows the event stream, and serves Inline's tools as a
client-hosted MCP server. An Inline thread and the owner's terminal see and
drive the same live session.

Requires OpenCode 2.2.0 or newer (`CORE_FLOOR`). Older v2 releases, and
`INLINE_OPENCODE_DRIVER=acp`, keep the ACP route in `inline-agent-driver-acp`.

## Service

The driver reuses the healthy service registered at
`$XDG_STATE_HOME/opencode/service.json` (default `~/.local/state`), with HTTP
basic auth when the service has a password. Without one it runs
`opencode service start` with Inline's secrets removed from the environment.
It never stops or replaces a service: other clients may use it. When the
event stream keeps failing, the link rediscovers the service, which may have
restarted on a new port.

## Mapping

| Bridge | OpenCode |
| --- | --- |
| open start / resume / fork | `POST /api/session`, `GET /api/session/{id}`, `POST …/fork {before}` |
| trusted guide | instruction entry `inline` (`<context key="inline">`, survives compaction) |
| turn, steer, queue | `POST …/prompt` with Inline's `msg_` id and `delivery` |
| passive context | `POST …/synthetic {resume: false}` |
| advertised commands | `POST …/command` |
| interrupt / cancel queued | `POST …/interrupt`, `DELETE …/inbox/{id}` |
| model, effort, permissions, mode | `POST …/model`, `PATCH … {permissions}`, `POST …/agent` |
| compact, rename, archive | `POST …/compact`, `PATCH … {title, archived}` |
| undo (rewind) | `POST …/revert/stage {messageID, files}` (commits on the next prompt) |
| approvals, questions | `permission.asked` → `…/permission/{id}/reply`; `form.created` → `…/form/{id}/reply` |
| side call (speak gate) | `POST …/generate` |
| stop a sub-agent | `POST /api/session/{child}/interrupt` |
| events | `GET /api/event` (volatile); repaired from `…/log?after=` |
| Inline tools | WebSocket `/api/experimental/client-mcp?name=inline` |

A turn is one OpenCode execution, named after the inbox entry that started it:
the id Inline gives a prompt is the id of its turn. Prompts carry
`metadata["inline.input"]`, so a resumed session still correlates them.
OpenCode admits a prompt id once, so a send whose response was lost is retried
with the same id. Sub-agent sessions (`subagent` tool) stream as child work of
their parent; their approvals are answered on the child session.

The client-MCP connection is per folder, so OpenCode also offers `inline_*`
tools to sessions Inline did not open in that folder; those calls are refused.
In Code Mode, OpenCode exposes them inside `execute` as `inline.<tool>`.

## Tests

- Unit tests cover the event mapper, catalog, SSE decoding and tool server.
- `tests/fake_service.rs` runs a full turn (approval, tool call over client
  MCP, catalog, side call) against an in-process fake of the service API.
- `tests/live_opencode.rs` qualifies a real OpenCode v2 (opt-in, see the file).
- `tests/live_lab.rs` exercises approvals, steer and queue, interrupt, Inline
  tools, questions, sub-agents, settings, commands, compact, fork, undo and a
  service restart against a real service. Point it at an isolated service by
  setting `XDG_STATE_HOME`, `XDG_DATA_HOME` and `XDG_CONFIG_HOME`.
