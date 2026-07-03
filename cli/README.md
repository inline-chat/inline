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
inline auth login
```

`auth login` is an interactive terminal flow. For agents, CI, or other
non-interactive environments, pass an existing token with `INLINE_TOKEN`:

```bash
INLINE_TOKEN=... inline auth me --json
```

`inline auth logout` clears the saved local token. It cannot unset a token
provided by the parent environment, so commands remain authenticated while
`INLINE_TOKEN` is set.

## Output

Use `--json` for automation and `--compact` for pipelines:

```bash
inline messages list --chat-id 123 --json --compact
```

`--translate` works in JSON output for `messages list`, `messages search`, the
top-level `search` shortcut, and `messages get`. For `messages export`, it
writes the raw history fields plus a top-level `translations` array:

```bash
inline messages export --chat-id 123 --translate en --output ./translated.json
```

List commands can pre-filter JSON payloads before printing:

```bash
inline chats list --json --filter "launch"
inline users list --json --filter "sam"
inline bots list --json --filter "deploy"
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

## Diagnostics

`inline doctor --json` reports system, client identity, config, path, and auth
state diagnostics. Client identity includes the CLI client type/version,
user-agent, OS version, and metadata header names sent to the API/realtime
server.

## Notes

The CLI is still early and may have bugs.
