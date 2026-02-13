# OpenClaw

Need a bot token first? See [Creating a Bot](/docs/creating-a-bot).

## Install / Update

```bash
openclaw plugins install @inline-openclaw/inline
openclaw config set plugins.installs.inline.spec '"@inline-openclaw/inline@latest"'
openclaw plugins update inline
```

## Configure

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
