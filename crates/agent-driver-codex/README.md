# Inline Codex Agent Driver

Direct, structured integration with `codex app-server` for Inline's local
coding-agent bridge. The driver owns Codex process supervision, JSONL protocol
compatibility, and event normalization; it does not own Inline presentation.
