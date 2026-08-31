---
title: "CLI"
description: "Install, sign in, find chats, send messages, and export transcripts."
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

Confirm which account will perform your commands:

```bash
inline me
```

The CLI acts as the signed-in user. Messages you send are visible to the destination's participants. It does not need a bot token for these commands.

## Find and Read a Chat

List your chats:

```bash
inline chats list
```

Filter by name, space, or ID:

```bash
inline chats list --filter "launch"
```

Use the returned chat ID in subsequent commands. Replace `123` below with your destination's ID.

```bash
inline messages list --chat-id 123 --limit 20
```

```bash
inline search --chat-id 123 --query "release"
```

## Send a Message or File

Check the chat's identity before sending:

```bash
inline messages send --chat-id 123 --text "The release is ready for review."
```

```bash
inline messages send --chat-id 123 --attach ./release-notes.pdf --text "Release notes"
```

`--chat-id` targets a chat; `--user-id` targets a direct message. Use one, not both. Reply to a message with `--reply-to <message-id>`.

## Export a Transcript

```bash
inline transcript --chat-id 123 --limit 500 --output ./launch-review.md
```

The limit bounds the export; this is not necessarily the full history. Exported messages and downloaded media are local copies of chat data. Review them before sharing or committing them.

## Scripts and Agents

```bash
inline messages list --chat-id 123 --limit 20 --json --compact
```

JSON mode returns RPC payloads rather than the terminal table. Do not parse table formatting in scripts. Some table-only filters are unavailable in JSON mode; consult the command's help.

Install the Inline skill for a coding agent:

```bash
inline skill install
```

Restart the agent after installation. See [Add Inline to Your Agent](/docs/add-inline) for other installation options, or [Agents](/docs/agents) to run an agent from Inline chats.

## Update and Troubleshoot

```bash
inline update
```

For a Homebrew installation, use `brew upgrade --cask inline`.

| Symptom | Check |
| --- | --- |
| `inline` is not found | Open a new terminal after installation; check that the install directory is on `PATH`. |
| A command or flag is missing | Check `inline --version`, update, then run the command with `--help`. |
| Authentication fails | Run `inline login`, then `inline me`. |
| A chat is missing | Verify the account with `inline me` and confirm that account can open the chat in the app. |

For a diagnostic summary, run `inline doctor`. Review diagnostics before sharing them. [Report a problem](/docs/troubleshooting#report-a-problem).

## Command Reference

```bash
inline messages send --help
```

Use `inline --help` for all command groups. [CLI reference and source](https://github.com/inline-chat/inline/tree/main/cli)
