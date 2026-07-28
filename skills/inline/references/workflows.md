# Inline workflows

## Resolve a target

1. Identify whether the user means a person, DM, space, or titled thread.
2. Call `people.search`, `spaces.list`, or `conversations.list` with the smallest useful query.
3. Compare names, usernames, titles, space context, recency, and match reasons.
4. If multiple candidates remain, ask the user rather than guessing.
5. Before writing, call `conversations.get` when participant or parent context could change the decision.

## Summarize a conversation

1. Resolve the conversation.
2. Call `messages.list` with a bounded `limit`, `since`, or `until`.
3. Page backward only if the requested period or unresolved context requires it.
4. Distinguish facts, decisions, proposals, open questions, and action items.
5. State the reviewed scope and any coverage limit.

## Search and investigate

1. Resolve one conversation; MCP message search is intentionally conversation-scoped.
2. Call `messages.search` with the query, time window, and optional content filter.
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
- Missing tools: ask the user to connect Inline MCP rather than fabricating output.
