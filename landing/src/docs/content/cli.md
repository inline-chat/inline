# CLI

Use the Inline CLI from a terminal, script, or coding agent.

## Install

Choose one installation method.

#### macOS · Homebrew

```bash
brew tap inline-chat/homebrew-inline && brew install --cask inline
```

#### macOS · Install script

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

#### Linux · Install script

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

The Linux installer supports x86_64 and ARM64 systems using glibc or musl.

## Sign in

```bash
inline auth login
```

## Install the Inline skill

Install the official skill for Codex and other compatible agent environments:

```bash
inline skill install
```

Restart your agent after installation so it discovers the skill.

## Common commands

- `inline chats list`
- `inline messages send --chat-id <id> --text "hello"`
- `inline search --chat-id <id> --query "<text>"`
- `inline --help`

For automation, full command coverage, and output formats, see the [CLI reference on GitHub](https://github.com/inline-chat/inline/tree/main/cli).
