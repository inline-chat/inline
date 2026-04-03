# OpenClaw

Need a bot token first? See [Creating a Bot](/docs/creating-a-bot).

## Setup

### Install

```bash
openclaw plugins install @inline-openclaw/inline
```

### Keep It Updated

Set the plugin spec to latest:

```bash
openclaw config set plugins.installs.inline.spec '"@inline-openclaw/inline@latest"'
```

Then update the installed plugin:

```bash
openclaw plugins update inline
```

## Config

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

Plugin entry id is `inline`:

```yaml
plugins:
  entries:
    inline:
      enabled: true
```

## Run / Verify

```bash
openclaw gateway
openclaw plugins list
openclaw status --deep
```

If a stale config appears, keep `plugins.entries.inline`.

## Report Issues

Report issues here: [inline-chat/inline issues](https://github.com/inline-chat/inline/issues).
