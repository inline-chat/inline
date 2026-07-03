# Inline CLI

Install the Inline CLI and have Claude/Codex interact with it.

## Install

### Homebrew (cask)

```bash
brew tap inline-chat/homebrew-inline
brew install --cask inline
```

### Script

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

Supports macOS and Linux (x86_64/aarch64, glibc and musl). Set
`INLINE_INSTALL_DIR` to choose a custom install directory.

## (Optional) Add the skill to Claude/Codex

Use the skill markdown at `cli/skill/SKILL.md`. Ask your agent to "create a skill"
and paste the markdown.

## Login

```bash
inline login
```

`inline login` is an interactive terminal flow. For agents, CI, or other
non-interactive environments, pass an existing token with `INLINE_TOKEN`:

```bash
INLINE_TOKEN=... inline me --json
```

`inline me` verifies the current auth state. `inline logout` clears the saved
local token. It cannot unset a token provided by the parent environment, so
commands remain authenticated while `INLINE_TOKEN` is set.

## Output

Use `--json` for automation and `--compact` for pipelines:

```bash
inline messages list --chat-id 123 --json --compact
```

Use batch selectors when an agent already knows the relevant message IDs:

```bash
inline messages get --chat-id 123 --message-id 91,92,100 --json
inline messages download --chat-id 123 --message-id 80-100 --dir ./media
inline messages download --chat-id 123 --from-msg-id 600 --limit 50 --dir ./media
```

Selectors support single IDs (`91`), comma lists (`91,92,100`), ranges
(`91-100`), and repeated `--message-id` flags. Batch downloads skip messages
without media, report skipped/missing/failed counts, and prefix local filenames
with the message date, `MSG` ID, media type, and media ID. For contiguous
windows, use `--from-msg-id ID --limit N` with export/transcript/download.

For reviewable conversation bundles, prefer transcript/export:

```bash
inline transcript --chat-id 123 --limit 500 --download-media --output ./feedback-bundle
inline transcript --chat-id 123 --limit 500 --download-media --media-dir ./feedback-media --output feedback.md
inline transcript --chat-id 123 --from-msg-id 600 --limit 50 --download-media --output ./feedback-bundle
inline messages export --chat-id 123 --limit 500 --format json --output feedback.json
inline messages export --chat-id 123 --limit 500 --format jsonl --output feedback.jsonl
inline messages export --chat-id 123 --limit 500 --format csv --output feedback.csv
```

`inline transcript` is a shortcut for `inline messages transcript`, a markdown
export optimized for reading: sender names, timestamps, replies, forwards, media
links, file links, and hidden message IDs. Markdown uses CDN URLs by default;
pass `--download-media` to download photos/files in one pass and rewrite
transcript links to local paths. Messages without media are skipped during media
download. If `--output` is a directory, or a no-extension path with
`--download-media`, the CLI writes `transcript.md`/`transcript.<format>` there
and defaults downloaded media to a `media/` folder inside it.

`--translate` works in JSON output for `messages list`, `messages search`, the
top-level `search` shortcut, and `messages get`:

```bash
inline messages get --chat-id 123 --message-id 91,92,100 --translate en --json
```

List commands can pre-filter JSON payloads before printing:

```bash
inline chats list --json --filter "launch"
inline users list --json --filter "sam"
inline bots list --json --filter "deploy"
inline messages list --chat-id 123 --has-media --json --compact
inline messages list --chat-id 123 --empty-text --forwarded
```

For advanced ad hoc analysis, jq is still useful on compact JSON:

```bash
inline messages list --chat-id 123 --limit 500 --json --compact | jq '.messages | length'
inline messages list --chat-id 123 --limit 500 --has-media --json --compact | jq -r '.messages[].id'
```

For message content from standard input, pipe or redirect the input. `--stdin`
fails fast when stdin is an interactive terminal:

```bash
echo "hello" | inline messages send --chat-id 123 --stdin
```

Human tables adapt to terminal width through `COLUMNS`. Set `NO_COLOR=1` to
disable color, or `CLICOLOR_FORCE=1` to force color in a non-TTY. Non-JSON
runtime errors print a short human report with an error code, and may include
status, API error, response preview, hint, and examples.

`inline chats list` gives chat titles extra room and wraps long titles onto a
second table row before truncating, so filtered chat searches stay readable.

## Diagnostics

`inline doctor --json` reports system, client identity, config, path, and auth
state diagnostics. Client identity includes the CLI client type/version,
user-agent, OS version, and metadata header names sent to the API/realtime
server.

## Notes

The CLI is still early and may have bugs.
