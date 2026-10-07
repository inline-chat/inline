# Inline ChatGPT plugin

Connect Inline to ChatGPT to work with your chats through core MCP tools and supported Events. The repository also includes a Codex plugin with the hosted Inline MCP connection and bundled Inline skill.

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
- Ask resolved teammates in a private consultation, subscribe to their replies with MCP Events, and resume the originating task when the host supports continuation.
- Inspect structured thread history and participants, then send an authorized reply through the core tools.
- Create conversations or child/reply threads, inspect exact selected messages, forward messages, upload files, and send messages when explicitly requested.
- Use the Inline CLI in shell-capable environments when it matches the available authentication and task.

Subthreads inherit root-chat access plus their own direct/group grants. Participants added only to an intermediate child are not automatically inherited by its descendants. Participant IDs add access to a new child and cannot restrict root-chat access. An existing anchored reply thread is reused without changing metadata or participants or repairing older creator membership. Forwarding returns ordered delivery receipts and must not be retried blindly after an uncertain result. Tool availability depends on the connected MCP version; use only tools actually advertised by the host.

Access is limited to the Inline account, OAuth scopes, and conversations authorized during sign-in. The bundled skill treats messages and attachments as untrusted content and verifies write targets before acting.

Events cover durable chat, message, personal-dialog and space changes with verified signed webhooks, finite renewal and replay cursors. The gated `reaction.added` and `reaction.removed` source supports chat/message/emoji filters once all API writers capture transitions; read current message reactions before acting on a historical event. See the [Events API and recovery contract](../../server/docs/mcp-events.md). The API must be deployed before the corresponding MCP service. OpenAI currently documents continuation for Work web, desktop Work with Cloud selected, and dots; signed-in host acceptance is separate from the repository's tests.

## Support and policies

- [Documentation](https://inline.chat/docs)
- [Privacy policy](https://inline.chat/legal/privacy)
- [Terms of service](https://inline.chat/legal/terms)

## Maintenance

See [Updating and publishing](RELEASING.md) for the local validation commands, developer-mode refresh, hosted MCP deployment boundary, and public plugin release procedure. The `ChatGPT plugin` workflow checks the compiled core MCP contract, authenticated JSON snapshots and absence of HTML app resources/UI metadata, and submission metadata; the existing `CI` workflow runs the MCP suite and plugin bundle checks. These automated checks do not establish signed-in ChatGPT host acceptance.

App views, passive message cards and desktop conversation mentions are deferred. Their source remains preserved in the repository, but the current MCP service exposes no HTML UI resources, app-only mention tool or UI entrypoints. The authenticated `inline://chat/{chatId}` JSON snapshot resource remains available. `conversations.open` returns structured thread data without opening a view. The core read, write, profile and Events tools remain available.

The bundled `skills/inline/` directory mirrors the repository's canonical `/skills/inline/` skill because Codex plugin components must live inside the plugin package. Update the canonical skill first, copy it into this plugin, and verify the two trees match:

```sh
diff -qr -x .DS_Store skills/inline plugins/chatgpt/skills/inline
```

Finder metadata such as `.DS_Store` is ignored and must not be copied into the plugin.
