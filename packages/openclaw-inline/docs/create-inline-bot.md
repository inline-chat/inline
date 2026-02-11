# Create an Inline Bot Token

Use either the macOS app or the CLI to create a bot and get its token.

## Option A: macOS App (Preferences)

1. Open Inline for macOS.
2. Open `Inline -> Settings…` (`Cmd+,`).
3. Go to `Bots`.
4. In `Create Bot`, enter:
   - `Name`
   - `Username` (must end with `bot`, case-insensitive)
5. Click `Create Bot`.
6. Copy the `New Token` shown after creation.

Notes:
- You can create up to 5 bots.
- In `Your Bots`, you can reveal or rotate tokens later.

## Option B: Inline CLI

1. Login:

```sh
inline auth login
```

2. Create the bot:

```sh
inline bots create --name "My Inline Bot" --username myinlinebot
```

Optional: add the bot to a space on creation:

```sh
inline bots create --name "My Inline Bot" --username myinlinebot --add-to-space 123
```

3. Reveal token:

```sh
inline bots reveal-token --bot-user-id <BOT_USER_ID>
```

Tip: if you do not know the bot user id:

```sh
inline bots list
```

## Use Token in OpenClaw

Set token under `channels.inline.token`:

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```
