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

## (Optional) Add the skill to Claude/Codex

Use the skill markdown at `cli/skill/SKILL.md`. Ask your agent to "create a skill"
and paste the markdown.

## Login

```bash
inline auth login
```

## Alias-Aware JSON Querying

The CLI now supports alias-aware query/path transforms on JSON output:

- `--query-path <PATH>`: select value(s) by dot/bracket path (repeatable)
- `--field <PATH>`: project paths from each item in an array (repeatable)
- `--jsonpath <PATH>`: JSONPath-like dot/bracket selector (repeatable)
- `--sort-path <PATH>`: sort current JSON array by a path
- `--sort-desc`: descending sort order (with `--sort-path`)
- `--jq <FILTER>`: apply jq filter (requires `jq` in PATH)

Rules:

- Aliases are rewritten only in selector/filter strings, never in API payload JSON keys.
- Long-form canonical keys still work exactly as before.
- Mixed-case tokens are not rewritten.
- Quoted bracket keys are treated as literals and are not rewritten (for example: `users["fn"]`).

## Before/After Examples

```bash
# Canonical path
inline doctor --json --query-path config.apiBaseUrl

# Short alias path (same result)
inline doctor --json --query-path cfg.apiBaseUrl

# Canonical user projection
inline users list --json --query-path users --sort-path first_name --field id --field first_name

# Short alias projection (same result)
inline users list --json --query-path u --sort-path fn --field id --field fn

# Preserve a literal key via quoted brackets (no alias rewrite of "fn")
inline users list --json --query-path 'u["fn"]'
```

## Query Key Alias Table

| Alias | Canonical key |
| --- | --- |
| `au` | `auth` |
| `at` | `attachments` |
| `c` | `chats` |
| `cfg` | `config` |
| `cid` | `chat_id` |
| `d` | `dialogs` |
| `dn` | `display_name` |
| `em` | `email` |
| `fid` | `from_id` |
| `fn` | `first_name` |
| `it` | `items` |
| `lm` | `last_message` |
| `lmd` | `last_message_relative_date` |
| `lml` | `last_message_line` |
| `ln` | `last_name` |
| `m` | `message` |
| `mb` | `member` |
| `mbs` | `members` |
| `md` | `media` |
| `mid` | `message_id` |
| `ms` | `messages` |
| `par` | `participant` |
| `ph` | `phone_number` |
| `pid` | `peer_id` |
| `ps` | `participants` |
| `pt` | `peer_type` |
| `pth` | `paths` |
| `rd` | `relative_date` |
| `rmi` | `read_max_id` |
| `s` | `spaces` |
| `sid` | `space_id` |
| `sn` | `sender_name` |
| `sys` | `system` |
| `ti` | `title` |
| `u` | `users` |
| `uc` | `unread_count` |
| `uid` | `user_id` |
| `um` | `unread_mark` |
| `un` | `username` |

## Notes

The CLI is still early and may have bugs.
