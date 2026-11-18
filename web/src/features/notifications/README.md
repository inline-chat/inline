# Notifications and badge (`web/src/features/notifications`)

Message notifications while the app is open (feature-map rule 12), the unread badge (rule 9) and the notification permission affordance, for one signed-in session. Framework-free TypeScript; no view, no DOM. The platform (`@inline/platform`) performs the effects; the session (`AccountSession` from `@inline/view/features`) supplies the data.

## The call the app shell makes

Once per signed-in session, beside the other session wiring in `web/src/app/runtime.ts` (`#wireSession`), and undone when the session ends:

```ts
import { systemClock } from "@inline/platform"
import { attachNotifications } from "~/features/notifications"

const notifications = attachNotifications({
  session,                    // AccountSession
  platform,                   // Platform (createWebPlatform)
  role: runtime.role,         // ReadSignal<CoreRole | undefined>: this context's link role
  clock: systemClock(),       // wall clock: message dates are compared with it
  storage: localStorage,      // remembers "Turn on notifications" was dismissed
  channel: new BroadcastChannel(`inline-notify/${apiOrigin}/${session.userId}`),
})
// while signed in: notifications.prompt (for the banner and Settings)
// on sign-out:
notifications()               // same as notifications.dispose(); also closes the channel
```

This replaces the runtime's own badge effect (`effect(() => platform.badge.set(session.badgeCount.get()))` and the `badge.set(0)` on teardown): the shell should keep one of the two, not both.

Optional: `settings` (`globalMode`, `chatMode(chatId)`, `soundEnabled`; Mac defaults until the protocol carries them), `badgeEnabled` (a signal for the badge setting), `onSound` (the sound hook), `contextId`.

## Pieces

| File | What |
| --- | --- |
| `attach.ts` | `attachNotifications(options)`: wires the three below; returns a dispose function carrying `prompt`, `controller` and `dispose` |
| `badge.ts` | `attachBadge({ count, badge, enabled? })`: keeps `platform.badge` equal to `session.badgeCount`. The platform applies the Mac debounce (decreases at once, increases after 500 ms). The first value, and the value after the setting is turned back on, are applied at once; dispose sets 0 at once |
| `notification-controller.ts` | `createNotificationController(options)`: subscribes to the core's `newMessages` feed, decides with `decideMessageNotification`, shows, closes on read, opens on click |
| `viewing.ts` | `createViewingTracker`: the chats the user is looking at, here and in the account's other tabs |
| `permission.ts` | `createPermissionPrompt`: `permission`, `showPrompt`, `requestPermission(gesture)`, `dismiss()` |
| `content.ts` | `notificationContent`, `notificationBody`: title and one-line body by the Mac rules |

## The chat's dialog

One lookup, no index of its own: the chat row's `dialogId` gives the dialog row (`rowKey("dialog", chat.dialogId)`), read from the view store (dialog IDs are the server's, not derived from chat IDs). The feed ships the chat and dialog rows of every entry; the session's `all` sidebar ships them for non-archived chats. A chat row without `dialogId` has no dialog here (the session's `dialogFor(chatId)` reads the same field; its own index of every dialog row is gone too). The controller's former private index (`dialog-index.ts`, which watched every published row) and its fallback to `session.sidebar.dialogByChat` are gone. `NotificationSession` now picks `dialogFor` instead of `core` and `sidebar` (`AccountSession` still fits, so `attachNotifications({ session, ... })` is unchanged).

## Notification rules

- **Source.** The core's `newMessages` query, subscribed for the controller's life in every context. The core lists only messages delivered live or by a catch-up page, first inserted, incoming, not silent, unread and at most 120 s old (`NEW_MESSAGES_RULE`), with the chat, dialog and sender rows, so any chat notifies, open or not. History pages, opening a chat and repairs never qualify. Each feed key is handled once, and each tag once (the last 1000), so a list replayed after a resync does not notify twice. An entry leaving the feed (released after 300 s or past the 50-entry limit) changes nothing on screen.
- **Decision.** `messageNotificationFacts` with the dialog's `notificationMode` as the chat mode, then `decideMessageNotification` with `mentioned` (the server's mention flag, on top of the entity check), `silent`, and the nudge, urgent nudge and call transcript flags from the row. `messageNotificationFacts` does not read `mentioned`, `silent` or the dialog mode yet, so they are applied around it here. The policy still checks: never the user's own message; still unread now (dialog `readMaxId`, or the resident chat's read state); at most 2 minutes old by `clock` (a second guard on the core's limit); the mode; never while viewing; an urgent nudge always notifies, with sound. Replies to the user (the replied message's author, or a reply thread's anchor, which the feed ships when on the device) count in `mentions` mode.
- **Viewing.** A chat in any pane of the workspace while the page is visible and focused. The Mac counts the key window's route and its reply-thread side pane; the web's panes are all on screen, so all of them count (not only the focused pane). Through `channel`, each context posts its viewing set and the leader also treats the newest non-empty set from another context as viewed, so a hidden leader tab does not notify for a chat the user reads in a follower tab.
- **Only the leader shows.** `role` `leader` (or `undefined`, a connector without an election) shows; followers mark feed entries as handled but never show, so two tabs never show the same message, and a follower that becomes leader does not replay what it already saw. The platform also ignores a tag it already showed in this context.
- **Presentation.** Tag `messageNotificationTag(chatId, messageId)` and group `chatNotificationGroup(chatId)`, the Mac identifiers. Direct message: title is the sender's display name, body the preview. Thread: title is the thread's title with its space (`Design (Acme)`), body `Sender: preview` (the Mac puts the sender in a subtitle, which page notifications lack). The body is exactly what `previewText` returns (one line, at most 240 graphemes, control and bidi override characters removed); media, nudges and service messages use the Mac labels (`🖼️ Photo`, `🎤 Voice message (1:15)`, `👋 Nudge`, `Pinned a message`). `data` is `{ kind: "message", chatId, messageId, userId }`, strings only.
- **Click.** The platform focuses the window; the controller opens `{ kind: "message", chatId, messageId }` in the workspace. A click carrying another account's user ID is ignored.
- **Read.** When the chat's read frontier (the sidebar dialog's `readMaxId`, or the resident model's `readState`) reaches a shown message, its notification closes, as the Mac's `NotificationSyncOps` (`messageId <= readUpTo`). Reads on another device arrive the same way.
- **Edit.** The Mac schedules only for new messages and does nothing to a shown notification when the message is edited; the same here (an edit changes a row, not the feed, so nothing is reconsidered).
- **Sign-out.** Dispose closes every notification this controller showed and clears the badge.
- **Sound.** Out of scope. `onSound({ chatId, messageId, urgent })` is called after a notification with sound is shown; the OS plays its own sound for page notifications unless `silent`.

## Permission

Nothing asks on load. `prompt.requestPermission(userGesture(event))` from a click or key handler asks the browser; `null` or a forged token resolves to the current state without asking (the platform checks too). `prompt.showPrompt` is true while notifications are available, permission is `default`, and the user has neither dismissed the affordance nor been asked once through it; `dismiss()` stores `inline:notifications:prompt-dismissed` (per origin, like the permission). Storage that throws is treated as empty.

## Per tab and shared

| | Per tab | Shared |
| --- | --- | --- |
| Badge | Title prefix `(n) ` and the favicon: each tab sets its own from the same count | The Badging API (`navigator.setAppBadge`) is per installed app; every tab writes the same value |
| Notifications | The feed subscription, handled keys and tags, the viewing set | Shown by the leader only; `BroadcastChannel` carries viewing sets |
| Permission | | Browser permission and the dismissal flag are per origin |

## Limits

- **The feed is the only source.** Windows are not watched. A core without the host's sync engine (some test and demo cores) keeps the feed empty and nothing notifies there. A window-based fallback was removed on purpose: it would also notify for messages the core excludes (silent sends, repairs) and could not tell an empty feed from a quiet account.
- The feed lists only what arrived after the subscription started; a new leader's core starts a new feed, so a message that arrives during a leader handoff may be missed.
- `countsAsUnread` and the account-wide notification mode and sound setting are not on the protocol; they default to counting, `all` and on (`settings` overrides them).
- Closing on read needs the chat's chat and dialog rows. The feed ships them with each entry and the session's `all` sidebar keeps non-archived chats; for an archived chat whose entry has left the feed, the rows may be gone from the store and a read elsewhere does not close its notification.
- A notified message that is later deleted is not closed: the UI has no deletion signal for a message outside a window.
- No avatar icon: the platform requires a same-origin or media-origin URL, which this module does not know yet.
- If a tab crashes while focused on a chat, its viewing set stays with the leader until another context of the account gains focus.
- In Electron the permanent leader is not a window; the shell must pass a `role` that is `leader` in exactly one window (or let main decide), or every window would show.

## Check in real browsers

- The permission prompt appears only from the click, in Chrome, Firefox and Safari; Firefox and Safari refuse prompts without a gesture.
- Clicking a notification focuses the tab (and its window) and opens the chat at the message; in Safari and Firefox the focus may be refused when the tab is in another window.
- A second `show` with the same tag replaces rather than stacks (Chrome, Firefox; Safari on macOS ignores `tag` in some versions).
- `close(tag)` on read removes the notification from the OS notification center, not only from the page.
- Two tabs: only the leader shows; reading in a follower tab while the leader tab is hidden does not notify.
- Title prefix and favicon in each tab; the app badge when installed as a PWA.

## Tests

`bunx vitest run src/features/notifications` from `web/` (28 tests). Badge: debounce and clearing, the setting. Notifications: a new message shows one notification with the right tag, title and preview; a chat with no subscribed window notifies and closes on a read reported elsewhere; a silent message does not; a chat set to mentions notifies only for `mentioned`, one set to none never; the dialog is the one `ChatRow.dialogId` names (a dialog whose ID differs from the chat's; a stray dialog row for the chat seen later is ignored; reading through it closes), and a chat row without `dialogId` falls back to the session's index; a feed entry dropped by the core leaves its notification open; a resync snapshot that replays an entry does not notify twice; a follower shows none and starts after becoming leader; viewing in a focused window suppresses and losing focus does not; opening and paging never notify; own and stale and already-read messages do not; urgent nudges notify while viewing; a click opens the message; reading closes up to the frontier; an edit leaves the notification; another tab viewing the chat suppresses it; dispose closes everything and unsubscribes. Permission: never asked without a trusted gesture; dismissal remembered, also with failing storage. Content: the Mac body rules and one-line output.
