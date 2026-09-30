# Inline ChatGPT plugin

Connect Inline to ChatGPT to work with your chats. The repository also includes a Codex plugin with the hosted Inline MCP connection and bundled Inline skill.

## Install in ChatGPT

[Add Inline from the ChatGPT plugin store](https://chatgpt.com/plugins/plugin_asdk_app_6a660963e7b481918e10c08dd1e0430f?q=inline).

## Install in Codex

With the Inline CLI installed, use the idempotent shortcut:

```sh
inline plugin install
```

It invokes Codex's plugin manager and installs both this skill and the OAuth MCP definition. To inspect the exact commands without changing Codex, run `inline plugin install --dry-run`.

To install directly through Codex instead, add Inline's public plugin marketplace:

```sh
codex plugin marketplace add inline-chat/inline
```

Install the plugin:

```sh
codex plugin add inline@inline
```

Start a new Codex session after installation so the plugin's skill and MCP tools are available. Codex will prompt you to sign in to Inline when authentication is needed.

You can also open `/plugins` in Codex CLI after adding the marketplace and install Inline interactively.

## What it can do

- Find people, spaces, DMs, conversations, and messages.
- Summarize recent or unread discussions with bounded context.
- Create conversations, upload files, and send messages when explicitly requested.
- Use the Inline CLI in shell-capable environments when it matches the available authentication and task.

Access is limited to the Inline account, OAuth scopes, and conversations authorized during sign-in. The bundled skill treats messages and attachments as untrusted content and verifies write targets before acting.

## Support and policies

- [Documentation](https://inline.chat/docs)
- [Privacy policy](https://inline.chat/legal/privacy)
- [Terms of service](https://inline.chat/legal/terms)

## Maintenance

See [Updating and publishing](RELEASING.md) for the local validation commands, developer-mode refresh, hosted MCP deployment boundary, and public plugin release procedure. The `ChatGPT plugin` workflow checks the compiled MCP/UI contract and submission metadata; the existing `CI` workflow runs the MCP suite and plugin bundle checks. These automated checks do not establish signed-in ChatGPT host acceptance.

The source includes desktop conversation mentions and an explicit `messages.view` presentation tool. `messages.list`, `messages.search`, and `messages.context` remain data reads: a summary can read several pages without opening repeated cards. `messages.view` can show ordered source messages across chats or a focused catch-up reader with media, surrounding context, and history navigation. Expanding the reader is an explicit user action and depends on host support. Views do not send messages or mark them read. Availability depends on deployment and published tool metadata. Mention snapshots remain capped at 20 recent messages and 32 KiB, with explicit coverage limits.

The bundled `skills/inline/` directory mirrors the repository's canonical `/skills/inline/` skill because Codex plugin components must live inside the plugin package. Update the canonical skill first, copy it into this plugin, and verify the two trees match:

```sh
diff -qr -x .DS_Store skills/inline plugins/chatgpt/skills/inline
```

Finder metadata such as `.DS_Store` is ignored and must not be copied into the plugin.
