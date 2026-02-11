# OpenClaw

Need a bot token first? See [Creating a Bot](/docs/creating-a-bot).

## Install / Update

```bash
openclaw plugins install @inline-chat/openclaw-inline
openclaw config set plugins.installs.openclaw-inline.spec '"@inline-chat/openclaw-inline@latest"'
openclaw plugins update openclaw-inline
```

## Configure

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

Plugin entry id is `openclaw-inline`:

```yaml
plugins:
  entries:
    openclaw-inline:
      enabled: true
```

## Run / Verify

```bash
openclaw gateway
openclaw plugins list
openclaw status --deep
```

If a stale config appears, keep `plugins.entries.openclaw-inline` (not `plugins.entries.inline`).
