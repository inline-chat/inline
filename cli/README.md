# Inline CLI

Install the Inline CLI and have Claude/Codex interact with it.

## Install

### Homebrew (cask)

```bash
brew tap inline-chat/homebrew-inline
brew install --cask inline
```

### Script

```bash
curl -fsSL https://inline.chat/cli/install.sh | sh
```

Supports macOS and Linux (x86_64/aarch64).

## (Optional) Add the skill to Claude/Codex

Use the skill markdown at `cli/skill/SKILL.md`. Ask your agent to "create a skill"
and paste the markdown.

## Login

```bash
inline auth login
```

## Notes

The CLI is still early and may have bugs.
