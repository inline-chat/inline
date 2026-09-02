# Inline CLI 0.7.7

Draft release notes. Publication and signed-artifact verification are pending.

- Discover commands offline with `inline capabilities` and `inline schema commands`, including flags, aliases, and supported values.
- Install the Inline Codex plugin with `inline plugin install`; preview the operation with `--dry-run`. The plugin includes the Inline skill and OAuth MCP configuration. Installation does not require Codex's optional JSON output support.
- Send rich Markdown from `--text`, `--stdin`, or `--text-file` without stripping indentation or trailing newlines. The bundled help and Inline skill document supported syntax, mention-offset behavior, and client limitations.
- Create child and reply threads, move threads, change archive/follow state, configure chat notifications, and pin or unpin messages through existing Inline APIs.
- List account sessions with `inline auth sessions` and revoke another session with `inline auth revoke-session`. Revocation requires confirmation; noninteractive JSON use requires `--yes`.
- Refined silver terminal wordmark, with narrow-terminal and `NO_COLOR` support.
- More reliable connection shutdown and session revocation events; authenticated V2 session conversion reuses the existing connection.
- Fix a debug-build stack overflow during TLS connection setup. Preserve structured errors and existing authentication boundaries.
- Continue local Codex sessions from Inline: browse projects and indexed sessions, load older results, import recent history, and resume the exact linked session. New conversations use provider defaults without requiring model or project choices.
- Recover an unavailable project through `/projects`; wait for configured providers to become ready before reporting bridge start, restart, or update success.

Codex continuity uses official app-server APIs with one interface controlling a session at a time. In a linked thread, `/stop` stops work and releases Inline when other Codex work is idle; wait for its confirmation before continuing in ChatGPT Desktop or Codex CLI. `/resume` refreshes recent history and reacquires the same session without sending a prompt. Linked-session prompts are enabled only after that sync succeeds; a prompt sent before resume gets a reminder and is not forwarded or replayed. New/headless chats are unchanged. `/close` remains an idle-release alias. Desktop and CLI launches stay unchanged. Continuous cross-app observation and simultaneous controllers are not enabled. `/projects` and **Browse all projects…** combine saved local Codex projects with registered folders, independent of recent sessions. **Pick a Folder…** works on the bridge-host Mac, including existing Mac clients. Project browsing supports up to 1,000 verified local roots. The session catalog includes completed CLI/headless exec work. History import includes up to 100 user/final messages and 512 KiB; tools, intermediate output, Cloud, archived and unindexed sessions are excluded. Session browsing is capped at 1,000 entries per picker.

The bridge adds a forward local SQLite migration to schema 30 and consumes additive optional session-parent metadata. It remains compatible with older servers by resolving missing parent metadata through the existing chat API; no new server RPC or database migration is required. The existing metadata-only error-reporting policy is unchanged; set `INLINE_CLI_TELEMETRY=off` to disable it.

Supported targets remain Apple-silicon macOS and GNU/musl Linux on ARM64 and x86-64. macOS artifacts must be signed and notarized before publication. Intel macOS is unsupported.

After publication, update using your existing installation method:

```sh
inline update
inline --version
inline update --check
```

For a Homebrew installation, use `brew upgrade --cask inline`.
