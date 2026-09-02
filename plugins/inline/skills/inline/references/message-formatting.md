# Message formatting

Send Markdown as the message text itself. Do not wrap the whole message in a code fence or send an HTML document. The server parses text and derives formatting; no extra rich-content field or format flag is needed.

- MCP: `messages.send.text`, `messages.send_media.text` (caption), and `messages.send_batch.items[].content` when `type` is `text`. In `/mcp/v2`, batch media content is an uploaded media ID, not a caption; use `messages.send_media` for captioned media. Legacy `/mcp` uses `items[].text` for text or captions.
- CLI: `inline messages send --text TEXT`, `--stdin`, or `--text-file PATH` (also `--text-file -` for stdin). With `--attach`, text becomes the caption. Whitespace and indentation are preserved. `inline messages edit` uses the same formatting.
- CLI `--mention USER_ID:OFFSET:LENGTH` supplies UTF-16 ranges into literal input and disables Markdown parsing. To combine formatting with mentions, use `[Name](inline://user?id=42)` instead, after resolving the correct user ID.

## Supported syntax

| Format | Input |
| --- | --- |
| Bold | `**bold**` or `__bold__` |
| Italic | `*italic*` or `_italic_` |
| Underline | `<u>underlined</u>` |
| Strikethrough | `~~removed~~` |
| Highlight | `==important==` |
| Inline code | `` `literal code` `` |
| Code block | Triple backticks or tildes on separate lines, with an optional language after the opening fence; four-space indented code also works |
| Link | `[label](https://example.com)`; reference-style Markdown links also work |
| Mention | `[Name](inline://user?id=42)` or a known `@username` |
| Thread link | `[[Title]](inline://chat?id=123)` |
| Heading | `# Heading` through `###### Heading` |
| Lists | `- item`, `1. item`; indent nested items |
| Checklist | `- [ ] todo` and `- [x] done` |
| Quote | `> quoted text` |
| Separator | `---` on a separate line, with blank lines around it |
| Table | Pipe table with a header separator row, as below; use text cells, not embedded images |
| Image | `![alt text](https://example.com/image.png)`; HTTP(S) sources only |
| Inline math | `$x^2 + y^2$` |
| Display math | `$$` on separate lines around TeX source |
| Disclosure | `<details>` or `<details open>`, `<summary>Title</summary>`, body Markdown, `</details>` on separate lines |
| Progress disclosure | `<summary kind="progress">Working</summary>` inside details; use only while work is ongoing |
| Footer | `<footer>Attribution or brief metadata</footer>` on its own line |

Use blank lines between blocks. Keep tables as Markdown tables, not fenced code. Backslash-escape Markdown punctuation to keep it literal, or use code spans/fences. Code contents are not interpreted as formatting. Math uses dollar delimiters, not `\(...\)` or `\[...\]`.

Rich blocks, new inline styles, and math display depend on the recipient's client/version and enabled renderer. Older clients may show a simpler text or TeX fallback. Math rendering supports a bounded TeX subset, not arbitrary LaTeX packages. Unrecognized or incomplete syntax may remain visible text; arbitrary HTML and footnotes are not supported. Image fetching can fail: prefer uploaded media (`files.upload` with MCP or CLI `--attach`) for local/private files.

## Copyable examples

MCP `messages.send` arguments (use a resolved chat ID):

```json
{
  "chatId": "123",
  "text": "# Update\n\n**Ready**: ~~old~~ ==new== <u>reviewed</u>\n\n| Task | Status |\n| --- | --- |\n| Tests | Passed |\n\n- [x] Checked\n- [ ] Ship"
}
```

For multiline CLI input, use a file or a quoted heredoc so the shell cannot expand backticks, dollar signs, or backslashes:

```bash
inline messages send --chat-id 123 --text-file report.md
inline messages send --chat-id 123 --text '**Ready** — `tests` passed'
inline messages send --chat-id 123 --stdin <<'MARKDOWN'
# Results

<details>
<summary>Calculation</summary>

$$
E = mc^2
$$

</details>

<footer>Prepared from the test report</footer>
MARKDOWN
```

These examples send recipient-visible messages; resolve the target and obtain the user's sending intent first.
