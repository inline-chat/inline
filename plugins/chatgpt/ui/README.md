# Inline thread UI for ChatGPT

**Parked: this UI is preserved in source and disabled in the hosted MCP service.** The core-only release does not register thread HTML, message cards, app-only conversation mentions or UI entrypoint metadata. Core tools, Events and authenticated JSON conversation snapshots remain available.

The real ChatGPT host exposed an unresolved failure: while sending, it replayed stale original `toolOutput`, rewinding or clearing the active thread view. This behavior is deferred, not fixed. Passing builds, component tests or compiled contract checks does not repair that host failure or enable the deployment's app-resource gates. The implementation notes below describe the parked component, not a live plugin capability. Do not enable or promise the view without a separately approved fix and real-host acceptance.

A single React thread view bundled into a self-contained MCP Apps resource. It is isolated from the general web client and has no browser account token, direct Inline API connection, global workspace sidebar, or persistent message database.

The exported `THREAD_RESOURCE_URI`, `THREAD_RESOURCE_MIME_TYPE`, and `THREAD_RESOURCE_HTML` constants come from `dist/index.js`; build this package before the MCP server. Every asset is embedded, so the runtime needs no asset copy or CDN for JavaScript/CSS.

```sh
bun run --cwd plugins/chatgpt/ui build
bun run --cwd plugins/chatgpt/ui typecheck
bun run --cwd plugins/chatgpt/ui test
bun run --cwd plugins/chatgpt/ui preview
```

The local preview uses invented sample data and a simulated host; it exercises the actual production component bundle, and cannot access an Inline account.

## Tool boundary

`conversations.open({ chatId })` provides the initial 50-message snapshot. Its structured content includes the existing conversation `chat`, `details`, and direct `participants` fields, plus `messages`, `nextOffsetId`, and `capabilities: { canSend }`. Omitting `chatId` may return `chat: null` for the global entrypoint; this never discovers all workspace chats. A create/ask receipt containing a resolved `chat` hydrates history through `conversations.open`, including an `isError` ask receipt that confirms thread creation but leaves question delivery uncertain. No seed question is retried. Optional `monitoring: { active, expiresAt }` must come from an acknowledged, live backend subscription. `expiresAt` accepts ISO 8601 or epoch seconds. The view never infers that ChatGPT is watching from a locally selected thread or button.

Direct app calls use the standard `tools/call` bridge:

- `messages.list({ chatId, limit: 50, offsetId })` loads earlier history. Recent refreshes use `conversations.open` so access and monitoring stay current.
- `messages.send({ chatId, text, replyToMsgId? })` sends recipient-visible text and replies. A matching `ok: true` response with a valid canonical `messageId` clears the draft; a missing/null receipt, failure or timeout leaves the draft and persists an unconfirmed-send fence. Refresh, picker eviction and remount cannot resend it. Up to 12 unresolved receipts are retained independently of the picker; reaching that limit blocks new sends until the user resolves one. The user must explicitly choose “Continue with a new message” to clear the old draft and write again.
- `ui/update-model-context` attaches only explicitly selected source messages, at most 10 excerpts of 1,200 characters, and their canonical chat/message IDs. It appears only when the host advertises this capability.

All tools recheck grants on the server. An absent send capability is read-only. Message contents are escaped text; exact supplied HTTPS links and available HTTPS media are rendered. No untrusted HTML or remote iframe is embedded. Photo, video, document and voice-message display use existing media summaries; reactions, editing, upload, typing and native calls are deliberately absent without complete adapters.

One foreground refresh owner calls `conversations.open` every 15 seconds while the component is visible, and when it gains focus. This rechecks current access and monitoring. The indicator confirms an active reply subscription for this connection; it does not identify which ChatGPT task owns that subscription. Absent monitoring clears the indicator, and an expiry timer clears it even when polling is unavailable. Loaded older pages and selections remain stable. A recent unfiltered page replaces its complete ID range so deleted messages do not remain on screen. History is bounded to 500 loaded messages; earlier history remains in Inline. Server MCP Events owns durable listening and ChatGPT resumption when the view closes.

Typed access denials and OAuth challenges clear fetched messages, remembered thread metadata, unsent drafts and selected excerpts, and fence outstanding reads. After a denial, eligible host notifications identify only a target: this component instance requires a fresh authorized read before restoring any content or thread title. Mirrored results for the current authorized thread do not trigger another opener; same-thread model notification changes appear on the next foreground poll or explicit refresh. Transient errors preserve the last authorized snapshot. Authored unconfirmed-send receipts remain fenced so loss of read access cannot make a later remount offer a duplicate send. Only full thread-opener snapshots with capabilities or confirmed create/ask receipts can target the view; data-only history notifications cannot replace it.

Fullscreen shows a sidebar even when only one thread is remembered; inline keeps the compact picker. Both remember at most 12 resolved thread references actually opened through the component; it never discovers or lists all Inline chats. Only thread references and unconfirmed send drafts enter optional host widget state; message history remains canonical backend data. In hosts without widget-state persistence, these references remain scoped to the current component instance.

## Resource policy and appearance

If a later release enables this resource, register it with `connectDomains: []` and `frameDomains: []`. Add only Inline’s verified media/avatar HTTPS origins to `resourceDomains`; images and media outside the host’s CSP fail to a named attachment. No wildcard CDN or third-party asset origin is required by this bundle.

The appearance uses Inline native source values: 28-point avatars and 14-point bubble corners from `MacTheme.Theme`, system light/dark blue and incoming gray from `ThemeCatalog`, and the `InlineAvatarCore` initials palette/hash. Reusable thread, message, media and host-adapter components form the foundation; no full web-app routing or auth shell is included.

The component uses the documented standard [MCP Apps lifecycle](https://developers.openai.com/plugins/build/app-quickstart), with optional [ChatGPT launch globals, presentation mode, and widget-state persistence](https://developers.openai.com/plugins/reference). Early standard results are retained until the component subscribes; an initial canonical `toolResponseMetadata` envelope takes precedence over plain `toolOutput`, preserving hidden denial metadata. A result from the current invocation takes precedence over saved active state. Without an invocation result, a saved active reference is restored through a fresh authorized read; incomplete canonical launch metadata waits for its result. No account or browser storage is added. Signed-in ChatGPT host rendering, resource CSP, approval behavior and foreground polling still require real-host acceptance.
