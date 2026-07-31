# Inline for Codex

Use Inline work chats from Codex through the hosted Inline MCP server and the bundled Inline skill.

## Install

Add Inline's public plugin marketplace:

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

The bundled `skills/inline/` directory mirrors the repository's canonical `/skills/inline/` skill because Codex plugin components must live inside the plugin package. Update the canonical skill first, copy it into this plugin, and verify the two trees match:

```sh
diff -qr -x .DS_Store skills/inline plugins/inline/skills/inline
```

Finder metadata such as `.DS_Store` is ignored and must not be copied into the plugin.
