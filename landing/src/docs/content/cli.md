---
title: "CLI"
description: "Install, sign in, find chats, send messages, and export transcripts."
---

## Install

#### macOS or Linux

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

Linux targets: x86_64 and ARM64, with glibc or musl. The installer selects a
matching published binary. On Umbrel, run it inside the existing Hermes
container and choose a persistent installation directory; see [Hermes setup](/docs/hermes).
Run `inline update` before setup to obtain the current stable release.

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

CLI uses your account, not a bot or bot token. It's extremely useful for pairing with your Codex/Claude/etc for chatting, searching, creating threads, summarizing, etc.

For a remote server without a browser:

```bash
inline login --browser --no-open
```

Open the returned approval URL on your own computer. Keep the command running
until approval completes, then run `inline me --json` on the server. Never copy
session files or print tokens to move authentication between hosts.

## Update

```bash
inline update
```

For a Homebrew installation, use `brew upgrade --cask inline`.

## Doctor

Run `inline doctor` and review the output if reporting a bug.

## Help

Use `inline --help` for all command groups. [CLI reference and source](https://github.com/inline-chat/inline/tree/main/cli)

## Source

- [CLI reference and source](https://github.com/inline-chat/inline/tree/main/cli)
