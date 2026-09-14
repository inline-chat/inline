# Inline Markdown

Inline parses a bounded Markdown authoring surface on the server. Do not assume every CommonMark or GFM feature is supported.

## Supported input

- Inline formatting: `**bold**` or `__bold__`, `*italic*` or `_italic_`, adaptive backtick code spans, `[label](url)`, email addresses, and plain URLs.
- Blocks: headings, ordered and unordered lists, task-list checkboxes, block quotes, GFM tables, thematic breaks, and fenced code opened by at least three backticks or tildes. A language may follow a code fence.
- Images: `![alt](https://example.com/image.png)`. Only HTTP(S) sources are eligible for Inline's asynchronous image projection. Optional exact size hints use `{width=640 height=480}` immediately after the image.
- Inline extensions: a line containing `<details>` or `<details open>`, followed by `<summary>Title</summary>` or `<summary kind="progress">Title</summary>`, body Markdown, and `</details>`; and a one-line `<footer>Brief metadata</footer>`.

Strikethrough, footnotes, arbitrary HTML, and other unlisted syntax are not formatting contracts. They remain visible as text when Inline cannot represent them.

## Parsing and streaming

Parsing proceeds from the start of each message snapshot. Completed blocks keep their boundaries. During edit streaming, a full-line opening code fence without a closing fence is code through the current snapshot's end. A complete `<details>` opener plus summary may likewise remain open through the snapshot's end, while a lone opener or partial summary stays literal. Other ambiguous incomplete inline syntax also stays literal until it becomes complete. Producers should still close fences and disclosures in final messages.

`parseMarkdown` in the realtime SDK and `parse_markdown` in the Bot HTTP API control this behavior. `false` preserves the supplied syntax literally. Bot HTTP sends and edits default to `true`; bot-authenticated realtime sends and edits also default to `true`, while human realtime calls default to literal text when the flag is omitted. MCP, the Inline CLI, OpenClaw, Hermes, and the local-agent bridge opt in explicitly for their normal authored output.

The stored message always retains a plain text/entity projection. Rich-block-capable clients additionally render headings, code, lists, quotes, tables, images/albums, disclosures, separators, and footers; clients without that renderer keep the plain projection instead of interpreting Markdown independently.
