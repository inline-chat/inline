# Mentions

`@` suggestions for the composer and the policy for mentioning someone who cannot read a private thread. Framework-free. Mac reference: `apple/InlineKit/Sources/InlineKit/ViewModels/MentionCandidatesSource.swift`, `MentionCompletionViewModel.swift`, `MentionedParticipantAddPolicy.swift`.

## Suggestions (`suggest.ts`)

```ts
const participants = createParticipantsModel({ client: session.client, chatId, viewerId: session.userId }) // ../chat-info
const mentions = createMentionSuggestions({
  client: session.client,
  viewerId: session.userId,
  participants,
  recentSenders: recentSenders(chatModel), // the ChatModel's rowKeys and row
  directPeers, // optional: the viewer's direct chats from the sidebar, as { userId, lastMessageDate, pinned }
})
createComposerModel({ ..., suggest: mentions.suggest })
// on chat close: mentions.dispose(); participants.dispose()
```

- **Who:** people with access to the chat (`participants.access`), members of the chat's space (`spaceMembers`, subscribed here), the space's user groups (`userGroups`), and the viewer's direct-chat peers; never the viewer. Each person once, under the strongest source: participant, space member, direct chat. People known only from a direct chat appear only when searched. People whose user row is not on the device are left out.
- **Order** (`MentionCompletionCandidate.precedes`): access first; then who spoke most recently in the chat (the newest 100 messages of the window); pinned direct chats; the latest direct message; then groups, participants, space members, direct-chat people; then name; then ID.
- **Filtering:** the shared matcher (`@inline/view/quick-search`), so case, accents, Persian and Arabic letter variants and scripts fold as in Quick Search. Results are bucketed as the Mac buckets them (exact username, exact name, whole words of a name, prefix, initials, substring, a group's description) and keep the order above inside each bucket. The matcher's fuzzy tier is not used (the Mac has no fuzzy mentions); its initials tier ("pm" for "Product Meeting") is a web addition, ranked below prefixes. Punctuation alone matches nothing. At most 50 rows (`limit`).
- **Rows** (`MentionSuggestion`, a `ComposerSuggestion`): `id` (`user:<id>`, `group:<id>`), `title` (display name or group name), `subtitle` (`@username`, or "Description - N people"), `avatar`, `item` (`{ kind: "mention", atom: { type: "mention", userId } | { type: "groupMention", groupId }, label }` with the Mac's label: "@First", a bot's name, "@Group"), and `mention` (`kind`, IDs, `bot`, `source`, `hasAccess`) for anything the list or the policy needs.
- **Live:** `suggest` reads signals, so the composer's list grows as the member list completes or a name arrives; it is synchronous for what is on the device. Row objects keep their identity while their row and access hold, so the list re-renders only what changed.

## Mention add policy (`add-policy.ts`, rule 14)

```ts
// In the chat pane, when a message with mentions is sent (after `accepted`):
const decision = mentionAddDecision(
  mentionedUserIds(entities),
  mentionAddContext({
    chat, // ChatRow
    viewerId: session.userId,
    messageCount: policyMessageCount({ loaded: chatModel.rowKeys.peek().length, hasOlder: chatModel.window.peek().hasOlder }),
    participantIds: participants.access.peek().userIds,
    pendingUserIds, // adds already on their way
    membership, // the viewer's MemberRow in the chat's space, if known (for owner/admin)
  }),
)
// { kind: "none" } | { kind: "autoAdd", userIds } | { kind: "prompt", userIds }
```

Only a private thread qualifies; the sender, people with access and people being added are left out; the rest are added at once when the chat has fewer than 10 messages or is a reply thread and the sender can remove participants (the creator, or a space owner or admin: `canRemoveParticipants`, since auto-add relies on Undo); otherwise the pane asks. The Mac counts the chat's messages on the device; `policyMessageCount` treats a window with older messages as at least 10, which asks rather than adds.

**Acting on it:** the contract now has `addChatParticipants { chatId, userIds, groupIds? }` and `removeChatParticipant { chatId, userId? | groupId? }` (durable). The chat info pane uses them (`features/chat-info/member-actions.ts`: `createMemberActions(...).add(userIds)`, with its optimistic list and outcomes); for rule 14 the chat pane posts `addChatParticipants` for `autoAdd` (and for the prompt's "Add"), passes the people on their way as `pendingUserIds`, and offers Undo as `removeChatParticipant` for each.

## Not in the contract yet

The Mac also offers the viewer's own bots everywhere (`OwnedBotsDirectory`) and bots' Agents, hides bots a viewer cannot reach (`BotVisibility`), and refreshes rosters every 5 minutes per mention session. None of these have queries yet; owned bots and Agents would slot into `candidates` with their Mac ranks.

## Tests

`bunx vitest run src/features/mentions` from `web/`: the base order with recent speakers, pinned and recent direct chats, groups with and without access, and the viewer excluded; buckets (exact username, exact name, whole words, prefixes in base order, substrings, descriptions); Persian with an Arabic yeh, accents and CJK; the atom, label and row fields for a person, a bot and a group, and stable identity; the list growing when the space's member list completes; recent speakers from a window; the rule-14 decision table, message counting, who may remove, and the context from a chat row and entities.
