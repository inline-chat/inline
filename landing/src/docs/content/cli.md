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

Open the returned approval URL on your own computer. After you sign in, enter
the 6-digit code the command printed to confirm the CLI. Keep the command
running until approval completes, then run `inline me --json` on the server. Never copy
session files or print tokens to move authentication between hosts.

## Agent signature

When a coding agent like Claude Code or Codex sends a message through the CLI, people see "Sent via Claude Code" under it. Add `--as-me` to send without it. Messages you send yourself from a plain terminal aren't signed.

## Listen for messages

`inline listen` streams new messages and reactions as they arrive, so an agent can wake when something happens instead of polling. With `--json`, each event is one line of JSON.

```bash
inline listen --sender-id 42 --json                    # anything user 42 posts
inline listen --chat-id 123 --with-threads --json      # a chat and its threads
inline listen --user-id 42 --once --timeout 2h --json  # the next DM from user 42, then exit
inline listen --mentions-me --contains deploy --json
```

Add `--name` to resume after the last delivered event when you run it again. Run `inline listen --help` for every filter and the event format.

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
