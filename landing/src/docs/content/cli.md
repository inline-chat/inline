---
title: "CLI"
description: "Install and authenticate the Inline command line tool."
---

Use the Inline CLI from a terminal, script, or coding agent.

## Install

#### macOS Homebrew

```bash
brew tap inline-chat/homebrew-inline && brew install --cask inline
```

#### macOS or Linux

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

Linux targets: x86_64 and ARM64, with glibc or musl.

Verify:

```bash
inline --version
```

## Sign In

```bash
inline login
```

## Install the Inline Skill

```bash
inline skill install
```

Restart the agent after installation.

## Common Commands

- `inline chats list`
- `inline messages send --chat-id <id> --text "hello"`
- `inline search --chat-id <id> --query "<text>"`
- `inline --help`

Run `inline --help` for the command reference. [CLI source](https://github.com/inline-chat/inline/tree/main/cli)
