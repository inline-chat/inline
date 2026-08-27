---
title: "OpenClaw"
description: "Configure the official Inline OpenClaw plugin."
---

Add Inline as an OpenClaw channel. You need an [Inline bot token](/docs/creating-a-bot) first.

## Install

```bash
openclaw plugins install @inline-openclaw/inline
```

## Configure

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

## Run

```bash
openclaw gateway
```

Verify:

```bash
openclaw plugins list
openclaw channels status
openclaw plugins inspect inline --json
```

## Update

```bash
openclaw plugins update inline
```

[Plugin source and reference](https://github.com/inline-chat/inline/tree/main/openclaw)
