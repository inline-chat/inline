# Typing

Compose activity: who is typing, uploading or recording in a chat, and this user's own. Mac reference: `apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift`, `apple/InlineMac/Features/Chat/Toolbar/ChatRouteToolbarTitleModel.swift` (`resolvedStatus`). Rule 11: typing is broadcast every 3 s and expires after 6 s; the expiry, stops and "a new message ends it" are the core's (`client/src/host/compose.ts`).

## Wording (`presentation.ts`)

`composeStatus({ activities, isDirect, user, length })` → `{ kind, text }` or undefined. Typing wins over everything else:

| | Thread | Direct message |
| --- | --- | --- |
| 1 typing | "Ada Lovelace is typing" | "typing" |
| 2 | "Ada Lovelace and Alan Turing are typing" | |
| 3 | "Ada Lovelace, Alan Turing and Grace Hopper are typing" | |
| 4+ | "Ada Lovelace, Alan Turing and 2 others are typing" | |
| short form (rows), 3+ | "Ada Lovelace and 2 others are typing" | |
| upload, recording | "Ada is sending photo" (first name), "sending video", "sending file", "recording voice" | "sending photo" |
| agent | "Working" | "Working" |

Kinds: `typing`, `working`, `recording`, `sending` (with `media`), all drawn in the accent color. Texts have no trailing ellipsis: `TypingLine` adds the Mac's animated dots (still under reduced motion). When several non-typing activities run, the strongest shows (recording, video, photo, file, then agent work). People whose user row is missing are left out, as on the Mac.

## Header (`createChatTyping`)

```ts
const typing = createChatTyping({ client: session.client, chatId }) // one per open chat; dispose with it
const subtitle = chatSubtitle({ connection: session.connection.get(), typing: typing.status.get()?.text, isDirect, peerIsBot })
```

Rule 15's order: the connection state first, then typing and other activity (this model), then bot status or local time for a direct message. `chatSubtitle` (`@inline/view/features`) takes the text as `typing`; when it returns `{ kind: "typing" }`, render `<TypingLine status={typing.status} />` so the accent and dots follow the activity's kind.

## Sidebar (`createComposeActivityIndex`)

```ts
const activity = createComposeActivityIndex({ client: session.client }) // one per session
// each row: useSignal(activity.forChat(chatId)) → { typing: boolean, status?: ComposeStatus } (short wording)
```

One `composeActions()` subscription for every chat; each row reads its own cached computed, which keeps its identity until that chat's line changes, so typing in one chat renders one row.

Wiring: `<SidebarView typingFor={(item) => activity.forChat(item.chatId)} … />` (`web/src/features/sidebar/README.md`, "Typing"); `RowActivity` is the sidebar's `SidebarActivity` as is. The sidebar draws it as the Mac does: the preview line becomes the accent text after an animated indicator, a compact row shows the indicator alone.

## Outgoing (`createComposeReporter`)

```ts
const reporter = createComposeReporter({ chatId, clock: browserClock(), client: session.client })
const stopFollowing = reporter.followComposer(composerModel.composer.doc) // typing on edits, a stop when emptied or sent
const end = reporter.beginActivity("uploadingPhoto") // attachments; "recordingVoice" for voice; call end() when done
// on chat close: stopFollowing(); reporter.dispose()
```

- `noteTyping()` sends `typing` at once, then at most every 3 s while typing continues; `stopTyping()` sends a stop only if typing was sent since the last stop; the next keystroke sends at once. `followComposer` does both from the composer's document (the first value, a restored draft, sends nothing; a draft switched in with `setDraft` counts as an edit).
- Activities are counted per chat; the strongest is reported (recording, video, photo, file); the stop goes out when the last ends. While one runs, typing is not reported and a typing stop cannot clear it. The core refreshes an ongoing activity every 3 s itself.
- `dispose()` stops whatever was reported. All time is the injected clock's.

## Tests

`bunx vitest run src/features/typing` from `web/`: wording for one, two, three and many, the short form, direct messages, activity names and priority, missing names; the header model over the core's resource including another chat's activity and the core's expiry; one row's computed changing per chat; outgoing refresh at 3 s, stop once, typing again at once, following a composer document, counted activities with priority, dispose, and the intent posted through the store client.
