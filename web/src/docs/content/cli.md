# CLI

Inline CLI is in alpha.
In this version, it is primarily optimized for AI and agent workflows. A more polished UX for regular users is coming.

## Install

### Homebrew (recommended)

```bash
brew tap inline-chat/homebrew-inline
brew install --cask inline
```

### Script

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

## Login

```bash
inline auth login
```

## Useful Commands

- `inline chats list`
- `inline messages send --chat-id <id> --text "hello"`
- `inline search --chat-id <id> --query "<text>"`

## References

- Source: `cli/`
- CLI README: `cli/README.md`
