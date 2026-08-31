---
title: "Troubleshooting"
description: "Diagnose sign-in, missing conversations, notifications, and agent setup; report a useful bug."
---

Check [service status](https://status.inline.chat) for a reported incident and [What's New](/docs/changelog) for release notes. Include your app or CLI version when reporting a problem.

## App and Account

| Symptom | What to check |
| --- | --- |
| Sign-in code has not arrived | Confirm the email address or phone number and check email spam filtering. Follow the app's resend guidance; do not repeatedly request codes or share them with support. |
| A conversation is missing | Confirm the signed-in account and Home/space context. On iOS, check **All Chats**, not only **Open**. Check that you still have access. |
| A private link will not open | The link does not grant access. Ask the thread creator to check participants; a space admin or owner can also manage participants in a space thread. |
| A reply seems to be missing | Open the reply thread from its parent message; check which conversation you are viewing. |
| No notification arrived | Check the conversation's notification settings, system notification permission, and Focus/Do Not Disturb. Following affects thread surfacing; choosing per-thread **All** notifications also enables Follow. |
| An action exists in docs but not your app | Check your build and [download/update path](/docs/downloads). App and CLI releases can differ. |

If a send remains uncertain after a connection problem, check the conversation before sending the same content again. Do not delete local data as a first troubleshooting step.

## Agents and Developer Tools

| Surface | First check | Detailed recovery |
| --- | --- | --- |
| CLI | `inline --version`, then `inline me` | [CLI troubleshooting](/docs/cli#update-and-troubleshoot) |
| Local agent | `inline bridge status` | [Setup recovery](/docs/agents#recovery) |
| MCP | Confirm the OAuth account and allowed context | [MCP troubleshooting](/docs/mcp#troubleshooting) |
| OpenClaw | Plugin version and channel status | [OpenClaw troubleshooting](/docs/openclaw#troubleshooting) |
| Hermes | `inline-hermes doctor --json` | [Hermes troubleshooting](/docs/hermes#update-and-troubleshoot) |
| Bot API | `getMe`, then one delivery consumer | [Update troubleshooting](/docs/bot-updates#troubleshooting) |

A connected bridge or gateway is only the first check. Test a short prompt and confirm a final response appears in the intended Inline conversation.

## Report a Problem

Email [hey@inline.chat](mailto:hey@inline.chat) with:

- What you expected and what happened.
- The shortest steps that reproduce it.
- Platform, OS version, app build, or CLI/integration version.
- Approximate time and time zone; whether it happens consistently.
- A redacted screenshot or exact error text, if useful.

Do not include tokens, sign-in codes, private keys, webhook secrets, full configuration dumps, or unrelated chat content. Review diagnostic output and exported transcripts before attaching them. [Security vulnerabilities](/docs/security#report-a-vulnerability) should be reported privately.
