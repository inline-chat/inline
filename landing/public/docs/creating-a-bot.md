# Creating a Bot

Source: https://inline.chat/docs/creating-a-bot

## macOS App

1. Open Inline for macOS.
2. Open `Inline -> Settings…` (`Cmd+,`).
3. Select `Bots`.
4. Enter `Name` and `Username` (must end with `bot`).
5. Click `Create Bot`.
6. Copy the `New Token`.

## CLI

```bash
inline auth login
inline bots create --name "My Inline Bot" --username myinlinebot
inline bots list
inline bots reveal-token --bot-user-id <BOT_USER_ID>
```

## Use Token in OpenClaw

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

Continue with [OpenClaw](https://inline.chat/docs/openclaw).
