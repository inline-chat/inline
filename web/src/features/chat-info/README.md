# Chat info

The `chatInfo` destination's pane and the participants model it shares with mentions. Mac reference: `apple/InlineMac/Views/ChatInfo/ChatInfo.swift` and `apple/InlineKit/Sources/InlineKit/ViewModels/ChatParticipantsWithMembersViewModel.swift`. Lab: `web/lab-chatinfo.html` (`web/src/lab/chatinfo/`).

## Files

| File | What |
| --- | --- |
| `participants-model.ts` | `createParticipantsModel`: who is in a chat, by the Mac's fallbacks. Framework-free. |
| `chat-info-model.ts` | `createChatInfoModel`: header, tabs, the participants list's keyboard controller, settings bound to the dialog intents. Framework-free. |
| `ChatInfoPane.tsx` | The view: header, tabs, participants (with Add People, the row context menu and the removal confirmation), settings. |
| `chat-media-model.ts` | `createChatMediaModel`: one shared-media tab over `chatMedia` (items, footer states, `loadMore`, `retry`, `sentinel`). |
| `media-grid.ts` | `createMediaGrid`: the photo grid's roving tab stop and keys; `columnsFor`. |
| `ChatMediaTab.tsx` | The media tab views: the grid of reserved square cells, file, voice and link rows, the footer. |
| `member-actions.ts` | `createMemberActions`: who may add and remove, optimistic list, outcomes, the refused-but-gone rule. |
| `add-people.ts` | `createAddPeople`: the picker over the space's members not in the chat. |
| `testing.ts` | `FakeChatCore` (a scripted core answering `chat`, `user`, `sidebar`, `chatParticipants`, `spaceMembers`, `userGroups`, `composeActions`, and settling intents by a chosen mode) and `testHarness`. Used by the tests here, in `mentions/` and `typing/`, and by the lab. |

## Participants model

```ts
const participants = createParticipantsModel({ client: session.client, chatId, viewerId: session.userId })
```

| Member | What |
| --- | --- |
| `source` | `resolving`, `direct` (peer), `space` (a public thread's space members), `chat` (a chat's own participants); `inherited` when it comes from the chat's root |
| `ids` | Row keys in the core's order (`userGroup:`, `member:`, or `user:` for a direct message). A list view observes only this |
| `member(key)` | One cached computed per key: `{ kind: "user", name, username?, bot, isViewer, role?, restricted, avatar }` or `{ kind: "group", name, subtitle, memberCount, avatar }`; identity kept while unchanged |
| `status` | `pending` (show nothing, not "empty"), `loading` (the device's list, a fetch running), `ready`, `failed` |
| `complete`, `showEmpty`, `counts` | The core's `roster.complete` (always for a direct message); empty only once answered; people and groups |
| `access` | Effective access: the list's people, group members, public members who can see public chats, plus the chat's own grants when it inherits. Mentions rank by it and the add policy checks against it |
| `chat`, `root`, `spaceId` | The chat's row, the top of its chain, the root's space |

Rules (Mac `ChatParticipantsWithMembersViewModel`): a chat with a parent inherits its top-level chat's list; a direct message lists its peer; a public thread in a space lists the space's members (the viewer first, then by join date); anything else its own participants (group grants by name, then people by name). A parent missing from the store is waited for `missingChatWaitMs` (1 s), then the chain ends where it is. When the source changes, the previous list stays until the new one is answered, so the list never flashes empty.

## Chat info pane

```tsx
// In the pane registry, for { kind: "chatInfo", chatId, tab }:
const model = useModel(
  () =>
    createChatInfoModel({
      client: session.client,
      chatId,
      viewerId: session.userId,
      dialog: session.dialogFor(chatId),
      intents: session.intents,
      offline: computed(() => session.health.get().kind === "offline"),
      tab, // any destination tab opens Participants where the chat has it
      onTabChange: (next) => session.workspace.replace({ kind: "chatInfo", chatId, ...(next ? { tab: next } : {}) }),
      onOpenProfile: (userId) => session.workspace.open({ kind: "user", userId }),
      copyText: (text) => navigator.clipboard.writeText(text),
      // New (media tabs): the session's media layer and the content views' handlers.
      media: {
        sources: shell.mediaSources,            // createCoreMediaSources (has createVisibility); without it cells stay placeholders
        onOpenMedia: (input) => shell.mediaViewer.open(input), // the app's viewer, as for message content
        onDownload: handlers.onDownload,        // the content views' download handler, when wired
        onOpenLink: (url) => handlers.onOpenUrl?.(url), // optional; default: a plain link (new tab, noopener)
      },
      // New (members): outcomes of Add and Remove for the app's toasts.
      onNotice: (notice) => toasts.show(notice.kind === "done" ? { tone: "info", text: notice.text } : notice),
    }),
  [chatId],
)
return <ChatInfoPane model={model} />
```

Every new option is optional: without `media` the media tabs list their rows (no thumbnails, nothing opens); without `onNotice` outcomes show only under the list.

- **Header:** avatar (emoji for a thread with one), title (Mac rule: a direct message's peer, else the thread's title), kind ("Direct message", "Bot", "Private thread", "Public thread", "Subthread", "Reply thread") and, once the list is complete, "8 participants", "3 participants, 1 group" or "120 members"; the chat ID with Copy ("Copied" for 2 s, in a status region).
- **Tabs** (kit `Tabs`), the Mac's order: Participants (threads only), Media, Files, Voice, Links, then Settings (the Mac's card). The destination's tab opens when the chat has it, else the first. `onTabChange` reports the destination tab, or undefined for Settings, which has no destination tab.
- **Media tabs** (`chatMedia`, filters `photosVideos`, `files`, `voice`, `links`). Each tab's model is made the first time it is shown and kept while the pane is open. The core lists what is on the device in its first answer (newest 2,000 rows read) and the server page fills in, so local rows show while it loads ("Loading…"). Media is a grid of square cells (`repeat(auto-fill, minmax(100px, 1fr))`, 4 px gaps, the Mac's adaptive grid), each reserving its square before anything loads; thumbnails come from `media.sources.photo(..., owner, thumbnail)` (a video's poster with `thumbnail`), held by the cell, and subscribe only for cells near the viewport (the media layer's visibility on the grid's nearest scrolling ancestor). Keys in the grid: arrows (mirrored in right to left), Up and Down by row, Home, End, Page Up and Page Down, Enter or Space opens (`onOpenMedia`); one tab stop. Files, voice and links are rows (file name without bidi controls, type, size and date; Download through `onDownload`; voice length and sender; a link's title, host or text with its URL through the link allowlist, opened in a new tab or `onOpenLink`). Footer: "Loading history…" while nothing is known yet, Load More (and automatically when the end of the list comes within a screen, and when the keyboard reaches the last row), "Couldn't load history." with Retry (subscribes again; the old rows stay until the new answer), and the Mac's empty words ("No media found in this chat.", "No files found…", "No voice memos found…", "No links found…").
- **Members** (`model.members`, `model.addPeople`, `model.participantMenu`, `model.removeDialog`). The Mac's `ChatParticipantPolicy`: Add People in a private thread (not public, not a direct message, not an inherited list); Remove for the thread's creator or a space owner or admin (the viewer's member row from `spaceMembers`, subscribed while the pane is open), never the viewer, never a row of an inherited list. Remove is in a row's context menu (secondary click or Shift+F10 on a row; `participantActions(key)` are its items, "Remove Participant" or "Remove Group Access") and asks first ("Remove participant?", "Remove Ada from this chat?"; groups with the Mac's longer text). The picker: a search field over the space's members not in the chat (and not being added), Up and Down move, Enter with text typed picks the active person (a chip) and clears the field, Enter with nothing typed adds the picks (or the active person), Backspace drops the last pick, Escape closes, a click picks or unpicks. Optimistic: added people appear at the end of the list and removed rows disappear in the same task; a refusal puts the list back. A refused remove is checked against the refetched list first (the core refetches after a refusal): if the person is gone (a remove retried after a lost acknowledgement), it counts as done; after `REMOVE_CHECK_MS` (8 s) without a refetch, it counts as refused. Outcomes show under the list (`members.state`, dismissable) and go to `onNotice`.
- **Participants:** the kit's `ListboxController` (`model.list`): arrows, Home, End, typeahead; Enter or a click opens the person's profile; groups open nothing (as on the Mac). Rows show "You", Owner or Admin and Restricted (space members), Bot, and `@username` or a group's "Description - N people". Each row reads only its own `member(key)` and its active flag; rows off screen skip layout (`content-visibility`). "Updating…" while loading; "No access grants found in this chat." only for an answered empty list.
- **Settings:** Notifications as a segmented choice (Default, All, Mentions, None: `setDialogNotifications`), Follow thread (threads: `setDialogFollow` following or unfollowed), Pin in sidebar (`setDialogPinned`), Archived (`setDialogArchived`), Mark as Unread (`markUnread`, disabled when already unread). Each control moves in the same task (the dialog row is predicted in the store's overlay) and moves back if refused. `control(id)` says what happened: `waiting` ("Saved on this device. Inline will sync it when you're back online."), `failed` with the kit-wide notice (offline, storage full, refused, unavailable), `uncertain` ("Not confirmed yet"); each can be dismissed.

## Not built, and why

Translation, visibility, the bot sections and the Mac's date sections in the media grid are not in this pass (the grid is one flat list, newest first). Voice rows show length and sender but do not play inline (the content views' player is not reused here yet). Links show the first link of each message, not one row per link.

## Invariants

- No first-frame empty: `pending` renders nothing; the device's list shows while the server fetch runs.
- One member changing re-runs one `member(key)` computed and renders one row; list membership changes render no existing row.
- No effects in the view; every subscription is owned by a model and released by `dispose()`.

## Lab

`web/lab-chatinfo.html`. State on `globalThis.__chatInfoLab`: besides the earlier fields, `members` (`canAdd`, `canManage`, `shown`, `state`, `question`, `dialogOpen`, `picker` with `open`, `query`, `matches`, `picked`, `active`), `media` (per tab: `count`, `footer`, `resource`), `grid` (`active`, `columns`), `ensures`, `mediaActions`, `notices`. Controls on `__chatInfoLabControl`: `selectTab(any tab)`, `nextPage(tab)`, `setMediaState(tab, "loading" | "failed" | "empty" | "normal")`, `gridKey(key)`, `openAddPeople`, `pickerQuery`, `pickerKey`, `addPeople(userIndexes)`, `requestRemove(index)`, `confirmRemove`, `cancelRemove`, `rowActions(index)`, `refusedButGone(index)` (a refused remove whose refetched list no longer has the person: it must end "Removed."). The private thread has 60 photos and videos (20 more on "the server"), four files, a voice memo and two links.

## Tests

`bunx vitest run src/features/chat-info` from `web/`: shared media (`shared-media.test.ts`: the filter per tab, local rows in the first answer with a loading footer, `ensure older` once and only when there may be more, prepared rows for files, voice and links with bidi stripping and the link allowlist, failed then Retry holding the rows, one row changing one item, the grid's columns, keys, right to left and tab stop, a tab's model made on first use, opening a photo, release on dispose, a local send's owner); members (`member-actions.test.ts`: who may add and remove for a member, an admin, the creator, a public thread; the picker's filtering, picks, Backspace and Enter; the add shown at once and confirmed; a refused add taken back; remove asks first and stays gone; a refused remove put back after the refetch; refused but already gone counts as done; the refetch wait times out; the row's menu items); the fallbacks (private thread with groups, subthread and reply thread inheriting with their own grants as access, public thread and its subthread with roles and restricted members, direct message, a parent that never arrives), pending then loading then complete, the empty state only when answered, holding the previous list across a source change, one member renamed re-running one computed out of 300; header and tabs for a thread, a direct message and a bot; tab changes as destination tabs; keyboard and Enter opening a profile; every settings intent with its same-task echo; outcome mapping for confirm, server refusal, storage full, unavailable, offline and uncertain; waiting while offline then confirmed; a late refusal and dismissal; no dialog row; copy.
