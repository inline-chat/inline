# Inline MCP workflows

## Resolve a target

1. Identify whether the user means a person, DM, space, or titled thread.
2. Call `people.search`, `spaces.list`, or `conversations.list` with the smallest useful query.
3. Compare names, usernames, titles, space context, recency, and match reasons. Use `conversations.list` with `spaceId` or `kind` to narrow the context before its result limit.
4. If multiple candidates remain, ask the user rather than guessing.
5. Before writing, call `conversations.get` when participant or parent context could change the decision.

## Summarize a conversation

1. Resolve the conversation.
2. Call `messages.list` with a bounded `limit`, `since`, or `until`.
3. Page backward with `nextOffsetId` as `offsetId` if the requested period or unresolved context requires it. The history scan examines at most 500 source messages per call; sender/time/content filters can return an empty page that still has a cursor. Calendar day boundaries use UTC.
4. Distinguish facts, decisions, proposals, open questions, and action items.
5. State the reviewed scope and any coverage limit.

## Search and investigate

1. Resolve one conversation; MCP message search is intentionally conversation-scoped.
2. Call `messages.search` with the query, optional `senderUserId`, time window, and optional content filter. Time/sender filters apply to the server search page after its limit; continue with `nextOffsetId` as `offsetId` even after an empty filtered result. `scannedCount` counts search matches inspected, not all underlying chat messages.
3. For each material hit, call `messages.context` around its message ID.
4. Use `files.get` when the user needs concrete media or attachment metadata.
5. Synthesize results without treating isolated hits as full context.

## Triage unread work

1. Call `messages.unread` with a reasonable limit and optional time window.
2. Group by conversation.
3. Prioritize explicit requests, blockers, mentions, decisions needed, and deadlines.
4. Fetch `messages.context` for items whose meaning depends on surrounding discussion.
5. Return a reviewable queue before sending replies unless the user explicitly requested action.

## Create a conversation

1. Determine whether it belongs in a space or Home.
2. Resolve the space and participants.
3. Confirm title and visibility when they are not obvious.
4. Call `conversations.create` once.
5. Use the returned `chat.chatId` for any initial post.

## Create a child or reply thread

Resolve the parent separately from the source of any selected messages. Call `conversations.create_subthread` with `parentChatId`, optional `parentMessageId` for an anchored reply, and optional title and additional `participantUserIds`. The child inherits root-chat access plus its own direct/group grants; a participant subset cannot restrict root-chat access. Participants added only to an intermediate child are not automatically inherited by its descendants. Title, description, emoji, and participants apply only to new creation. An existing anchored reply thread is returned without changing these values or repairing older creator membership. Use the returned child `chat.chatId` for delivery. If the parent is a DM, creating the child also requires access to Home threads in the grant.

## Forward selected messages

Resolve the source, authors, and destination independently. Inspect the relevant source window with `messages.list`/`messages.search`, and use `messages.get` for exact chosen IDs. Missing IDs must be resolved before delivery. Pass those peer-local IDs in the intended order to `messages.forward({ sourceChatId, destinationChatId, messageIds })`; repeated IDs create repeated deliveries. The returned `messages` pairs map each source occurrence to its destination ID. Fetch those destination IDs with `messages.get` to verify them. Reply relationships and reactions are not transferred. If delivery fails or its result is lost, inspect the destination before retrying; no idempotent replay is available.

## Send text

1. Confirm the target and whether the message is a new post or reply.
2. Preserve the user's intended text; draft when wording is not final.
3. Call `messages.send` once with the resolved `chatId`.
4. Report the returned message ID and target. Do not retry blindly after an uncertain transport failure because duplicate sends are possible.

## Send media

1. Confirm the source, target, media kind, filename, and caption.
2. Call `files.upload` with `sourceType: "base64" | "url"` and put the corresponding base64 payload, data URL, or HTTPS URL in `source`.
3. Use the returned media kind and ID in `messages.send_media`.
4. For several ordered normal, non-reply items, prefer one `messages.send_batch` call whose items contain only `type` and `content`; use individual send tools for replies or silent delivery.
5. Report partial batch failures item by item; do not resend successful items.

## Recover safely

- Unknown target: resolve again or ask the user.
- Missing scope: request reauthorization; do not switch identities or contexts.
- Unknown session: reconnect the MCP session and repeat only read operations automatically.
- Uncertain write result: inspect the target before retrying to avoid duplicates.
- Missing selected access path: use another already available and authorized Inline path when it fits; otherwise ask the user to connect MCP or install or authenticate the CLI as appropriate for the environment.
