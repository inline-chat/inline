---
title: "CLI"
description: "Install, sign in, find chats, send messages, and export transcripts."
---

## Install

#### macOS or Linux

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

Linux targets: x86_64 and ARM64, with glibc or musl.

#### Homebrew

```bash
brew tap inline-chat/homebrew-inline
brew install --cask inline
```

Try it:

```bash
inline --version
```

## Sign In

```bash
inline login
```

Confirm your login:

```bash
inline me
```

CLI uses your account, not a bot or bot token. It's extremely useful for pairing with your Codex/Claude/etc for chatting, searching, creating thread, summarizing, etc.

## Update

```bash
inline update
```

For a Homebrew installation, use `brew upgrade --cask inline`.

## Doctor

Run `inline doctor` and review the output if reporting a bug.

## Help

Use `inline --help` for all command groups. [CLI reference and source](https://github.com/inline-chat/inline/tree/main/cli)
