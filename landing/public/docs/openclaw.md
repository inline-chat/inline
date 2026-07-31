# OpenClaw

Source: https://inline.chat/docs/openclaw

Add Inline as an OpenClaw channel. You need an [Inline bot token](https://inline.chat/docs/creating-a-bot) first.

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

Verify that the Inline channel is available:

```bash
openclaw status --deep
```

## Update

```bash
openclaw plugins update inline
```

For access controls, troubleshooting, and the complete feature reference, see the [Inline OpenClaw plugin](https://github.com/inline-chat/inline/tree/main/openclaw).
