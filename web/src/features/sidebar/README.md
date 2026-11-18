# Sidebar

`SidebarView` renders the session's `SidebarModel` (`web/packages/view/src/features/`): a header slot, the Inbox / All chats switch, the chat list, the "unread below" button and a footer slot. The model owns the data and its order; `SidebarController` (framework-free) owns windowing, keyboard, focus, row positions, the context menu target and the unread-below state; the `.tsx` files only render. Lab: `web/lab-sidebar.html` (source in `web/src/lab/sidebar/`).

## Mounting

```tsx
import { SidebarHandle, SidebarView, basicActions } from "~/features/sidebar"

const sidebarHandle = new SidebarHandle()            // once per shell; stable
session.attachView({ focusRegion: (region) => region === "sidebar" && sidebarHandle.focus(), ... })

<SidebarView
  model={session.sidebar}
  density={settings.sidebarDensity}                  // "standard" | "compact"
  ready={sidebarReady}                               // see "Rules", 2
  actions={(item) => basicActions(item, handlers)}   // or the command registry's
  typingFor={(item) => activity.forChat(item.chatId)} // activity = createComposeActivityIndex({ client }), once per session
  onOpened={(event) => { /* move focus to the composer if the shell wants that */ }}
  handle={sidebarHandle}
  header={<SpaceHeader />}
  footer={<SidebarFooter />}
/>
```

The view fills its container (`block-size: 100%`) and paints `color.sidebarBackground`. Give it the split view's sidebar pane.

| Prop | Default | What |
| --- | --- | --- |
| `model` | required | `session.sidebar`. A new model builds a new controller. |
| `density` | `"standard"` | Mac "Item size": standard rows are 40 px with a 30 px avatar and a preview line; compact rows are 30 px, 22 px, one line. Changing it rebuilds the controller (rare: a setting). |
| `unreadStyle` | `"count"` | Mac `UnreadBadgeStyle`: a trailing count (a dot for a mark), or a 5 px leading dot. |
| `ready` | always ready | `ReadSignal<boolean>`: the core answered the current mode's list. Without it, an empty list shows the empty state at once. |
| `actions` | none | `(item) => SidebarAction[]` for the context menu. Without it, secondary click shows the browser's menu. `basicActions(item, handlers)` builds the feature map's basic set shaped like the Mac menu. Actions: `{ id, label, shortcut?, keyshortcuts?, enabled?, destructive?, run }`, `{ kind: "radio", id, label, checked, run }`, `{ kind: "submenu", id, label, actions }`, `{ kind: "separator", id }`. |
| `typingFor` | none | `(item) => ReadSignal<{ status?: { kind, text } } \| undefined> \| undefined`: who is composing in the item's chat. The typing feature's `createComposeActivityIndex({ client }).forChat(item.chatId)` fits as is. A change renders that row alone (see "Typing"). |
| `onOpened` | none | `({ key, chatId, intent, via })` after a row opened its chat. |
| `openIntent` | `openIntentFor` | Replace the modifier-to-intent map. |
| `handle` | none | A `SidebarHandle`: `focus()`, `revealSelected()`, `snapshot()`. |
| `os` | detected | Which modifier is "command" (Cmd on Mac, Ctrl elsewhere). |
| `header`, `footer` | none | Slots. The footer gets a top separator. |
| `showModeSwitch` | `true` | The Inbox / All chats switch, bound to `model.mode` and `model.setMode`. |
| `label` | `"Chats"` | The listbox's accessible name. |

`actions`, `typingFor`, `onOpened` and `openIntent` are read when they fire (`typingFor` when a row first shows an item), so inline functions are fine. `ready`, `handle`, `os`, `label` and `model` rebuild the controller when their identity changes: keep them stable.

## Rules a caller keeps

1. Never reorder or filter what the list shows. The core orders `sidebar.items` (rules 6 to 8); the view never reorders. A row that should not be there is the core's to drop.
2. Pass `ready` from the session if you can. It is what keeps the list from ever flashing empty: until it is true an empty list shows a static placeholder (no spinner, `aria-busy`), and after a mode switch the previous list stays on screen (busy) until the new one is answered. The model cannot tell this yet (see "Needs").
3. Focus stays in the list after opening a chat. If the shell wants the composer focused after a click, do it in `onOpened` (for example only when `via === "pointer"`).
4. "Focus sidebar" is `handle.focus()`; it focuses the selected chat's row, else the last focused row, else the first, scrolling it into view.
5. Previous and next chat stay the registry's commands (`sidebar.selectAdjacent`). The list leaves Alt+Up and Alt+Down, Cmd/Ctrl shortcuts and every key it does not handle to the app.
6. Do not mount two `SidebarView`s on one model with one `handle`: the handle follows the last one mounted.

## Behavior

- **Rows**: avatar (a user's photo or initials on the Apple avatar color; a thread's emoji, bare in compact rows, or initials), title (`dir="auto"`), a one-line preview with "Draft:" before a draft, unread as a count (`99+` cap) or dot, accent for prominent unread (rule 9) and gray for muted, a pin when pinned with nothing unread, selected background for the chat in the focused pane, and a ring on the context menu's row. Hover changes only the background. Rows are absolutely positioned at `index × rowHeight`, so nothing shifts.
- **Renders**: rows are recycled slots (`slots.ts`): each `memo` row reads which key its slot shows, that key's `model.item(key)` and its context-target flag through `useSignal`. A key keeps its slot while it stays in the window. One chat changing renders one row; selection renders two; a reorder inside the window renders none, because the controller moves rows (`transform`, `aria-posinset`, `tabindex`, `id`) without React; scrolling renders only the slots whose key changed, reusing their DOM. The list component renders only when the number of slots changes (the window grows).
- **Fast scrolling**: a scroll event that moves more than half the viewport marks the scroll fast; rows entering the window then draw lite (the avatar's color and the title, no initials, image, preview or badge). 120 ms after the last fast event, lite rows fill in, 8 per frame, visible ones first. Slow scrolling (wheel, trackpad, keys) never draws lite.
- **Keyboard** (one tab stop, roving `tabindex`): Up, Down, Home, End, Page Up and Page Down move focus without opening (no wrap, as on the Mac). Enter and Space open; with the command modifier a new tab, with Option or Alt the other pane, with both a new pane (`openIntentFor`). Typing searches titles over the whole list (Space continues a search; a pause of 500 ms resets it). Shift+F10 and the context menu key open the row's menu. While the list does not have focus, its tab stop follows the selected chat; when the selection changes from elsewhere, the selected row scrolls into view.
- **Pointer**: click opens with the same modifier map; middle click opens a new tab; secondary click opens the row menu at the pointer with the caller's actions, live while open (a row that changes while its menu is open updates the entries).
- **Row menu** (`controller.contextMenu`, the kit's `LazyContextMenu`): the menu's code is not on the first frame. The first secondary click, context menu key or Shift+F10 loads the kit's menu chunk (or the app warms it on the idle lane: see `web/packages/ui/README.md`, "Menus load on first use"); the browser's menu never shows meanwhile, the row's ring shows at once, and the menu opens at the same place when the code arrives. `SidebarView` renders `LazyMenuContent`. Item names are the label alone; shortcuts are `aria-keyshortcuts`.
- **Menu entries** (`basicActions`): for a temporary row Close from Sidebar, Keep in Sidebar; otherwise Pin or Unpin, Mark Read or Mark Unread, Close from Sidebar, Archive or Unarchive (the Mac's `SidebarNativeRowView` order); then **Notifications ▸** Default, All, Mentions, None (radio, the current one checked: `item.notificationMode`, absent is Default; the Mac's chat toolbar popover, `DialogNotificationSettingSelection`) with `setNotifications(item, mode)` → `setDialogNotifications { chatId, mode }`, and **Follow Thread** or **Unfollow Thread** for a thread (not a direct message; `item.followMode === "following"`) with `setFollow(item, mode)` → `setDialogFollow { chatId, mode: "following" | "unfollowed" }`; then Copy Link. `dialogSettingActions(item, handlers)` builds the settings part alone.
- **Typing** (Mac `SidebarNativeComposeActivityView`): while someone composes in a chat, a standard row's preview line shows the activity ("Ada is typing", short wording from the typing feature) in the accent color after a 16 by 12 indicator (three bobbing dots for typing and sending, three pulsing bars for recording, a turning ring for agent work; still under reduced motion); a compact row shows the indicator alone after the title, before the badge. The row's accessible name says the activity in place of the preview. `controller.activityOf(key)` is a cached per-key computed that compares statuses by value: typing in one chat renders one row, the 3 s refresh of the same activity renders none.
- **Unread below** (Mac `SidebarUnreadBelowButton`): a 28 px button at the bottom with the count of prominent unread chats below the viewport (a row cut by the edge counts as visible); it scrolls the nearest one to the center, jumping first when it is more than a viewport away (Mac `SidebarUnreadScrollPlan`), instantly under reduced motion. Tracking starts after the first paint, since it reads every item.
- **States**: a first-load placeholder (static rows, `aria-busy`, a hidden "Loading chats" status) only while `ready` is false and nothing is listed; an empty state per mode once answered.
- **Styling**: StyleX with the kit's tokens only, logical properties only (the one translate is vertical), `light-dark()` colors, stronger selection under `prefers-contrast: more`, a `Highlight` outline for the selection under forced colors, motion from the kit's tokens (0 ms under reduced motion).

## Scale: windowing, and why

An account can have thousands of chats. The list is **windowed**: it renders the rows that intersect the viewport plus 8 on each side, plus the roving focus row wherever it is (about 30 to 45 rows, whatever the list length).

Why not render every row with cheap rows:

- **DOM budget.** A row is about 10 nodes; 5,000 rows are about 50,000, against the budget of about 15,000 for the whole app (`docs/performance.md`, "Bounded DOM").
- **First paint.** Mounting 5,000 components with a store subscription each costs tens of milliseconds on the throttled profile, against 150 ms for the whole warm start. `content-visibility` would skip layout and paint, but not node creation or React's work.
- **Fixed heights make it exact.** Mac rows have one height per density, so an index maps to an offset by arithmetic: no measuring, no estimates, no jumps.

What stays honest:

- **Keyboard**: navigation works on the model's keys, not on rendered rows. The focused row is always rendered (as an extra row if outside the range), so Tab and focus never land on a missing element; moving to an unrendered row scrolls first and focuses it when it mounts.
- **Typeahead**: searches titles over the whole list, reading items lazily from the current position, so it finds row 4,000 as easily as row 4.
- **Screen readers**: every option carries `aria-setsize` (the list length) and `aria-posinset`; the listbox is `aria-busy` while a list is held or loading. DOM order is slot order, not list order (the cost of recycling); arrow-key navigation, which moves real focus, and the position announcements follow the list. Empty spare slots are `hidden`.
- **Find in page**: the browser's find only sees rendered rows. This is a decision, not an accident: Cmd/Ctrl+F is the app's Find in chat, and finding a chat by name is Quick Search's job (Cmd/Ctrl+K), as on the Mac, whose sidebar has no find either. Rendering hidden `hidden="until-found"` copies of every title was considered and rejected: two nodes per chat (10,000 for 5,000 chats) blows the DOM budget, and Safari in our browser floor does not support it.

Recycling also keeps focus simple: React never moves or remounts a row element (slots are keyed by slot number), and the focused key always stays in the window, so its element keeps focus through reorders and scrolling. When the focused chat leaves the list, focus moves to the row now at its position.

### Scroll performance, before and after recycling

| Run (Chromium, production build, 5,000 chats, unthrottled M-series) | Longest frame | Rows rendered | Max rows in one frame |
| --- | --- | --- | --- |
| Before: mount and unmount by key, `scrollTest()` fling over 120 frames | 17 to 18 ms warm, 97 ms first run after load | 3,117 | 27 |
| After: recycled slots, lite rows while fast | not measured yet | | |

The "after" run is the coordinator's: `__sidebarLabControl.scrollTest()` (fling) and `scrollTest(120, 20)` (slow) now report frame median, 95th percentile and max, script per frame (scroll event to the next animation frame callback: the list's handling and React's commit), `long-animation-frame` entries where the browser has them, rows rendered while scrolling, per frame and during fill-in, and visible options. Expected: no mounts while scrolling, cheaper row updates during a fling, and few or no row renders in most frames of the slow scroll.

## Files

| File | What |
| --- | --- |
| `SidebarView.tsx` | The region: slots, mode switch, scroller and listbox, first-load and empty states, unread-below button, context menu content. |
| `SidebarRow.tsx` | `SidebarRow` (a memo recycled slot: empty, lite or full) and `SidebarAvatar`. |
| `icons.tsx` | Pin and down-arrow glyphs. |
| `sidebar-controller.ts` | `SidebarController`: window, slots, fast-scroll lite rows, roving focus, keys, typeahead, pointer, context menu target, row placement, unread below. |
| `handle.ts` | `SidebarHandle`. |
| `geometry.ts` | Row metrics per density, visible range, window keys, reveal offset, unread below, the Mac's unread scroll plan. |
| `keyboard.ts` | `openIntentFor`, `pointerOpenIntent`, `listKeyAction`, `moveIndex`. |
| `typeahead.ts` | Lazy title search and its buffer. |
| `slots.ts` | `assignSlots`, `enteringKeys`: which key each recycled row shows. |
| `actions.ts` | `SidebarAction`, `toMenuEntries`, `basicActions`, `dialogSettingActions`, `NOTIFICATION_CHOICES`, `notificationChoiceOf`, `canFollow`. |
| `activity.ts` | `SidebarActivity`, `SidebarTypingSource`, `sameActivityStatus`: the typing prop's types. |
| `labels.ts` | Every string, the row's accessible name, badge text. |
| `avatar.ts` | Initials and colors cached per name (the kit's `initials` builds an `Intl.Segmenter` per call). |

## Tests

`bunx vitest run src/features/sidebar` from `web/`: geometry, keys and intents, typeahead (including that it reads lazily), labels, actions, the avatar cache, and the controller over a real `SidebarModel`, store client and scripted core (window bounds at 5,000 rows, window identity on item change versus reorder, slots kept across a reorder and reused by slow scrolling, lite rows on a fling and their fill-in per frame, loading versus empty, the list held across a mode switch, roving focus and its window, opening with intents, selection following and reveal, typeahead across the whole list, unread below and its scroll, context menu entries through the lazy menu, per-row compose activity notifying one row, the handle), and the menu's Notifications submenu and Follow item (`labels.test.ts`). No DOM: the parts are not attached in these tests.

## Check in a real browser

The lab (`lab-sidebar.html?count=5000`) exposes `__sidebarLab` (state) and `__sidebarLabControl` (operations returning `{ name, rows, lists, total, ms }`, and `scrollTest()`).

- Render budgets: "New message", "Unread +1", "Draft", "Pin", "Typing", "Recording", "Working" and "Stop typing" render 1 row and 0 lists (`__sidebarLabControl.typing(position, kind?)`, `stopTyping(position)`; the same activity twice renders 0); "Reorder visible" renders 0 rows and 0 lists; opening a chat renders 2 (old and new selection). Scroll test at 5,000: no frame over 32 ms on 4x throttling, under about 50 options in the DOM, lite rows filled in after a fling with no visible jump.
- Keyboard only: Tab lands on the selected row; arrows, Home, End, Page keys, typeahead (Latin, Arabic, CJK titles), Enter, Cmd/Ctrl+Enter (new tab), Alt+Enter (other pane); focus stays on a row when "New message" moves it; the focus ring shows only for keyboard focus.
- Focus survives a reorder that moves the focused row, and moves to a neighbor when the focused row is closed.
- Context menu: right click, Shift+F10 and the context menu key; Escape returns focus to the row; the row ring shows while open. The first one loads the menu's code: no browser menu in between. `__sidebarLab.menu` lists the open menu's items (`name` is `aria-label`, `keyshortcuts`, `checked` for the Notifications radios); Notifications ▸ and Follow Thread act on the lab core (`__sidebarLab` shows the row change).
- Typing: "Typing" on a standard row replaces the preview with the accent line and dots; on a compact row only the dots show, before the badge; `__sidebarLab.activity` lists chats with activity.
- Unread below: appears when prominent unread chats are below, counts them, scrolls smoothly (instantly under reduced motion) and centers the target.
- Restart with latency "never": placeholder, never "No open chats"; with 2000 ms and a mode switch, the previous list stays until the answer.
- Light and dark, right to left (dot and badge sides, ellipsis side, header and footer), high contrast and forced colors, compact and standard, a narrow sidebar (180 px).
- Screen reader: option names, position "n of 5,000", selected state.

## Header

The sidebar's title strip is the app's (`web/src/app/SidebarColumn.tsx`, `TitleStrip`), not this folder's. It already keeps the title's priority: the strip is an inline-size container and `UpdateButton` shows "Update ready: Reload" as an icon button (its words as name and tooltip) below 320 px. Nothing here to change; `IconButton` now also takes `shortcut` and `keyshortcuts` should a strip control want a shortcut in its tooltip.

## Needs from others

- `SidebarModel`: a `ready` (answered) signal per mode, and holding the previous list across `setMode` in the model; then the view's hold and the `ready` prop can go.
- `SidebarItem`: the last message's sender for thread previews ("Ada: …").
- Done (fifth integration pass): `SessionActions.sidebarActionsFor` lists Notifications ▸ and Follow or Unfollow Thread after Archive, and `SidebarRowAction` takes the `radio` and `submenu` variants; the app passes `typingFor`.
- The command registry should own the modifier-to-intent map; Cmd-click will collide with multi-select toggling (phase 3).
