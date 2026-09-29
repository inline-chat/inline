# Inline recipes

These recipes use Inline MCP. In a shell-capable environment, use the [Inline CLI reference](inline-cli.md) to install or authenticate the CLI and for CLI equivalents or bulk workflows.

## “What needs my attention?”

1. `messages.unread({ limit: 50 })`
2. `messages.context(...)` for ambiguous or high-priority items.
3. Group by chat and return urgent asks, blockers, decisions, and FYIs.

## “Summarize yesterday in Project Alpha”

1. `conversations.list({ query: "Project Alpha" })`
2. `conversations.get({ chatId })` if the match is not unique.
3. `messages.list({ chatId, since: "yesterday", until: "yesterday", limit: 50 })`
4. Page only if the result indicates more relevant history.

## “Find the discussion about launch dates”

1. Resolve the conversation with `conversations.list`.
2. `messages.search({ chatId, query: "launch dates", limit: 20 })`
3. `messages.context({ chatId, anchorMessageId, before: 8, after: 8 })` for material hits.

## “Find the files from that design thread”

1. Resolve the thread.
2. `messages.list({ chatId, content: "files", limit: 50 })`
3. `files.get({ chatId, messageIds: [...] })` for exact file metadata.

## “Message Sam that I’ll review it today”

1. `people.search({ query: "Sam" })`
2. Resolve ambiguity and use the returned `dmChatId`; optionally verify with `conversations.list`.
3. `messages.send({ chatId: dmChatId, text: "I’ll review it today." })`

## “Reply to this message”

1. Resolve the containing conversation and inspect context.
2. Draft if the requested wording is not explicit.
3. `messages.send({ chatId, text, replyToMsgId })`

## “Create a private project thread and post this update”

1. Resolve the parent space and participant user IDs.
2. `conversations.create({ title, spaceId, isPublic: false, participantUserIds })`
3. `messages.send({ chatId: created.chat.chatId, text })`

## “Post these notes and attachments in order”

1. Resolve and verify the target.
2. Upload each attachment with `files.upload({ sourceType, source, ... })`.
3. Build ordered items shaped exactly as `{ type: "text" | "photo" | "video" | "document", content }`; `content` is text or the uploaded media ID.
4. `messages.send_batch({ chatId, stopOnError: true, items })`
5. Report sent and failed indices without repeating successes.

## “Show links shared this week”

1. Resolve the conversation.
2. `messages.list({ chatId, content: "links", since: "1w ago", limit: 50 })`
3. Fetch context only for links whose surrounding discussion matters.

## Collect authored messages into a child thread

Resolve the source DM/person and destination parent independently. Read only the relevant source window and author, and inspect the exact selection before writing:

```text
people.search({ query: "PERSON" })
messages.search({ chatId: "SOURCE", query: "TOPIC", senderUserId: "AUTHOR", limit: 20 })
messages.get({ chatId: "SOURCE", messageIds: ["91", "92", "100"] })
conversations.create_subthread({ parentChatId: "PARENT", title: "TOPIC", participantUserIds: ["USER"] })
messages.forward({ sourceChatId: "SOURCE", destinationChatId: "CHILD", messageIds: ["91", "92", "100"] })
messages.get({ chatId: "CHILD", messageIds: ["RETURNED_DESTINATION_IDS"] })
```

Use real returned IDs. Page search with `nextOffsetId` when needed; the sender filter applies to each fetched search page. The child inherits root-chat access plus its own direct/group grants; participants added only to an intermediate child are not automatically inherited by descendants. If you supply `parentMessageId`, reuse of its existing reply thread does not change metadata or participants or repair older creator membership. Inspect delivered messages before retrying an uncertain forward.
