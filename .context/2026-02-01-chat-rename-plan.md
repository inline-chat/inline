# Chat Rename Plan (iOS + macOS)

## Scope
- Add server + protocol support for updating chat title/emoji.
- iOS: add edit button in Chat Info (non‑DM) to edit emoji + title.
- macOS: add “Rename Chat…” in toolbar menu; allow double‑click inline title edit (Finder‑style, save on Enter); include emoji editing from menu.

## Steps
1) Review current Chat Info + toolbar surfaces and confirm UX/patterns.
2) Add RPC + update types in proto (core + server), regenerate protos.
3) Implement server handler + update pipeline (DB update, updateSeq/lastUpdateDate, push updates, sync mapping).
4) Add InlineKit transaction + update apply + sync filter.
5) Implement iOS Chat Info edit UI and wire to transaction (non‑DM only).
6) Implement macOS rename UI (menu sheet + inline title edit) wired to transaction.
7) Run focused Swift build(s) for touched packages; summarize and note readiness.
