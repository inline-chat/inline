# Inline CLI

Install the Inline CLI and have Claude/Codex interact with it.

For setup failures, repeat the command with `--verbose` (twice for trace detail).
See [diagnostics and optional error reporting](../docs/cli-diagnostics.md).

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

## (Optional) Install the Inline skill for Codex

The CLI bundles the complete skill directory from `skills/inline/`, including
its references and OpenAI metadata. Installation is local and does not require
Node.js or a network request:

```bash
inline skill install
```

The command installs to `$CODEX_HOME/skills/inline` when `CODEX_HOME` is set,
otherwise `~/.codex/skills/inline`. It is idempotent when the installed files
match. If an existing skill differs, review it before using
`inline skill install --force`; force overwrites only bundled Inline files and
preserves extra files.

For other supported agents, the broader Skills ecosystem installer can install
the public source directly:

```bash
npx skills add https://github.com/inline-chat/inline/tree/main/skills/inline --global --yes
```

## Login

```bash
inline login
```

`inline login` without phase flags remains an interactive terminal flow.
On macOS, if a supporting Inline app is installed, the CLI offers to continue
with the signed-in app or use email/phone. App login opens a local approval
prompt with a verification code; approval creates a separate revocable CLI
session and returns its credential over an ephemeral loopback connection.
Agents and other non-interactive sessions can start and finish login explicitly:

```bash
# 1. Send a code. Email flows return challengeToken in the JSON result.
inline login --email you@example.com --send-code --json --compact

# 2. Verify the code and save the token without printing it.
inline login --email you@example.com --code 123456 --challenge-token TOKEN --json --compact

# Avoid putting the code in argv when it is available on stdin.
printf '%s\n' "$LOGIN_CODE" | inline login --email you@example.com --code-stdin --challenge-token TOKEN --json --compact
```

Phone login uses `--phone` in both steps and does not normally need a challenge
token. The successful JSON result reports `status: "authenticated"`, `userId`,
and whether the profile loaded; it never includes the bearer token.

Agents and CI may also pass an existing token with `INLINE_TOKEN`:

```bash
INLINE_TOKEN=... inline me --json
```

`inline me` verifies the current auth state. `inline logout` clears the saved
local token. It cannot unset a token provided by the parent environment, so
commands remain authenticated while `INLINE_TOKEN` is set.

## Local coding agents

One command can discover an agent already installed on this machine, create or
reuse its Inline bot, install the Inline integration, configure owner-safe
access, and start its gateway or bridge:

```bash
# Machine-readable, read-only discovery for apps and agents.
inline agents discover --json --compact

# Interactive picker; only installed agents are shown.
inline agents setup

# Prompt-free setup for agents and scripts.
inline agents setup --target openclaw --non-interactive --json
inline agents setup --target hermes --profile work --non-interactive --json
inline agents setup --target codex --folder /path/to/project --non-interactive --json

# Equivalent shortcuts for gateway targets.
inline setup openclaw --non-interactive --json
inline setup hermes --profile work --non-interactive --json
```

Supported installed targets are OpenClaw, Hermes, Codex, OpenCode, Claude, and
Amp. Inline does not install those host runtimes. If none are installed, setup
stops without creating a bot or changing configuration. Use `--dry-run` for a
read-only discovery check, `--no-install` to forbid integration installation,
or `--no-restart` to configure without changing the user service. The default
access mode is owner-only; automation can use `--access allowlist` with repeated
`--allow-user ID` flags. Codex/ACP bridge targets use the user's home directory
as their workspace unless `--folder` is provided explicitly.

Unified discovery and setup JSON include `protocolVersion` and
`documentationUrl`. Setup failures also include `status`, `failedPhase`,
`changes`, and `retry`; `status: "partial"` means setup may have changed state,
while `changes` contains only confirmed completed work. Errors use stable codes and safe hints so an app or agent
can offer a retry or send the user to the setup guide without parsing terminal
output. The JSON never includes bot tokens or local executable/workspace paths.

For gateway targets, `~/.inline/config.toml` stores only the target, profile
instance, bot user ID, and bot username needed for idempotent reconciliation.
Tokens stay in OpenClaw or Hermes credential storage. Codex/ACP mappings remain
in the existing bridge account state instead of being duplicated in this file.

Inline can also keep Codex and ACP agents available as private, local-first bots
in your chats. The older provider-specific setup commands remain supported and
use the same setup core. Setup is persistent; you do not run a new bridge per
thread.

```bash
inline setup codex --folder /path/to/project
inline setup opencode --folder /path/to/another-project
inline setup claude --folder /path/to/project
inline setup amp --folder /path/to/project
inline bridge status
```

Fixture-certified Codex 0.146.0 and the signed ChatGPT.app bundled Codex
0.150.0-alpha.8 on macOS are the intended invite-beta targets. Setup can use
the signed ChatGPT runtime without a standalone Codex CLI and leaves sign-in to
Codex/ChatGPT. Agent
directions work in the bot DM, direct mentions, replies, and followed threads,
but only for the owner by default. Other stable Inline user IDs must be added
locally with `inline bridge operators add USER_ID`; provider-specific overrides
use `--provider`. OpenCode, Claude, and Amp are experimental provider paths for
developers. Amp setup installs Inline's source-revision-pinned ACP adapter and
uses the exact authenticated host Amp CLI accepted during setup. All configured
providers can coexist under one supervised background service. See
[Local coding-agent bridge](../docs/local-agent-bridge.md) for provider support,
folder switching, lifecycle, and security details.

During a turn the bot silently edits one progress message, leaves it as a short
terminal status, then sends the final answer as a separate normally-notifying
message. Its persisted send identity is reused across retries and service
restarts so an ambiguous response does not create another final answer.

## Output

### Everyday shortcuts and scope

Singular command names work alongside the original groups: `chat`, `thread`,
`message`, `user`, `space`, and `bot`. List commands accept `ls`; chat, message,
and user `get` commands also accept `view`. Help displays these aliases.
Common flags have short forms: `-c` for a chat, `-u` for a DM user, `-L` for a
limit, `-q` for a search query, `-f` for a list filter, and `-m` for message text.
`-v` still prints the version.

```bash
inline chat ls --space-id 7 --unread -L 20
inline chat ls --home --type thread
inline chat ls --type dm --pinned
inline search "release checklist" -c 123 --offset-id 500 -L 50
inline search -c 123 --filter documents --ids
inline message ls -c 123 --has-media --ids
```

Scope filters combine with `--filter` and run before `--limit`/`--offset` in
both human and JSON output. `--home` means chats outside spaces, including DMs
and Home threads; use `--type thread` to exclude DMs. `--unread` includes manual
unread marks. `--id` requires exactly one match and cannot be combined with
pagination, which could otherwise conceal ambiguous matches.

Search accepts one quoted positional phrase or repeated `--query`/`-q` flags;
the two forms cannot be mixed. `--offset-id` uses the existing search cursor.
Words within one query are ANDed; repeated queries are ORed. Search also accepts
`--filter photos|videos|photo-video|documents|links|voice-memos`, with optional
query text. Media filtering runs on the server before its result limit.
Time/media filters on message lists, and time filters on search, apply to the
fetched page; they do not scan all history. `--ids` on message lists and search
prints peer-local message IDs without fetching the chat catalog for names.
It cannot be combined with `--json` or `--translate`.

### Shell completions

Generate completions from the CLI's current command tree. Generation is local:
it does not read account configuration, connect to Inline, or start the runtime.

```bash
inline completion bash > inline.bash
inline completion zsh > _inline
inline completion fish > inline.fish
```

Bash can source `inline.bash`; put `_inline` in a directory on Zsh's `fpath`
before running `compinit`; put `inline.fish` in Fish's completion directory.
`powershell` and `elvish` are also supported. `completions` is an alias.
The command writes the script to stdout and never edits shell startup files.
Hidden internal commands and flags are omitted. A pipeline consumer closing
early is handled quietly instead of printing a panic.
`--json` is rejected because the output is a shell script.

The upstream generator has shell-specific limits: Fish does not offer flags
for commands nested beyond two levels, such as `bridge workspace add`.
PowerShell and Elvish stop detecting the command path at the first flag, so
place global flags after the command path when using their completions
(for example, `inline message send --json`).

### JSON and text

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

Use `--text-file` with send/edit to preserve indentation and trailing newlines:

```bash
inline message send -c 123 --text-file ./update.md
inline message edit -c 123 --message-id 456 --text-file ./update.md
printf '  indented text\n' | inline message send -c 123 --text-file -
```

File input accepts nonempty UTF-8 up to 1 MiB and cannot be combined with
`--text` or `--stdin`. The server's message limits still apply. Existing
`--text`/`--stdin` trimming and precedence are unchanged; use `--attach` for
files that should be uploaded instead of read as message text.

Human tables detect the current terminal width on Unix; `COLUMNS` overrides
the detected width and also works in pipes. Chat/user/message tables and chat/
message details escape terminal control characters from content. JSON and
exports preserve original strings. Set `NO_COLOR=1` to
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

## Development

Before committing CLI changes, run the local pre-commit check:

```bash
bun run --cwd cli precommit
```

That uses the pinned Rust toolchain in `cli/rust-toolchain.toml`, runs
`cargo fmt`, applies machine-fixable clippy suggestions, runs `cargo fmt`
again, then runs the same `bun run --cwd cli ci` command used by GitHub
Actions. CI keeps rustfmt as the formatting authority; clippy still denies
warnings, but allows format-argument style churn such as inlined format args.

## Notes

The CLI is still early and may have bugs.
