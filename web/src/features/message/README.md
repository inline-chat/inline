# Message views

The rows of the message list: a message in the Mac app's default (bubble) style, the day separator, the unread line and the loading row, plus row actions (hover and focus quick actions, the context menu). The timeline package places them in its scroll container; these views only render what they are given.

Lab: `web/lab-messages.html` (`src/lab/messages/`). `?theme=dark&dir=rtl&counts=1` sets the starting state.

## Components

### `MessageRowView` (memoized)

| Prop | Type | Notes |
| --- | --- | --- |
| `message` | `MessageRow` | The row as the view store has it. A new object re-renders the row. |
| `firstInGroup`, `lastInGroup` | `boolean` | From the timeline's `MessageItem`. First shows the sender's name; last shows the avatar and the bubble's tail. |
| `context` | `MessageRowContext` | Shared by every row of a list; see below. Keep its identity. |
| `sender` | `SenderPresentation?` | From `presentSender(user)`. Needed for others' messages outside DMs. |
| `reply` | `ReplyPresentation?` | From `presentReply(...)` when `replyToMessageId` is set. Without it the line says "Original message". |
| `highlight` | `number?` | Flash the row once. Pass a new number per flash (the timeline's `highlight.seq` when its `key` is this row); undefined for none. |
| `itemKey` | `string?` | Written as `data-timeline-key`. |
| `tabIndex` | `number?` | For the list's roving tab stop. Rows are not focusable by default. |

`MessageRowSignalView` takes `row: ReadSignal<MessageRow \| undefined>` instead of `message` and reads it with `useSignal`, so a change to one message re-renders that row and a list change re-renders none. It renders nothing while the row is missing.

`MessageRowContext`, created once per list (and again only when one of its fields changes):

| Field | Notes |
| --- | --- |
| `times` | `createMessageTimes(createTimeFormatter(...))`. Times and tooltips are cached per minute; the tooltip is formatted on first hover. |
| `isDM` | Direct message chat: no names or avatars. |
| `interfaceDir` | Optional `"ltr"` or `"rtl"`. When set, every row writes it as its own `dir`, so nothing above the rows can make a row follow its text. Unset, rows inherit. |
| `handlers` | `MessageRowHandlers`: `onReplyClick(rowId, messageId)`, `onReactionClick(rowId, reaction)` (`reaction.mine` says remove or add), `onSenderClick(userId)`, and `MessageText`'s `onMention`, `onThreadRef`, `onBotCommand`, `onAppLink`, `onExternalLink`. |
| `actions` | `MessageActionsController?`. Without it, rows show no quick actions and have no menu. |
| `content` | `MessageRowContentSource<ReactNode>`: **the content slots** (see "Content slots"). Build it once with `slottedContent(render)` and keep it. |
| `highlightRangesFor` | Optional `(rowId) => ReadSignal<FindRanges \| undefined> \| undefined`: find in chat. Pass `findHighlights.rangesFor` (see "Find in chat"). |
| `emojiEngine` | Optional `ReadSignal<EmojiEngine \| undefined>`: the emoji feature's `services.loader.engine`. Chips are then named "thumbs up, 3, including you" (`reactionChipLabel`); before it loads, or without it, by the emoji ("👍, 3, including you"). Its one change (the data arriving) re-renders the rows that have reactions, once. |
| `reactorsFor` | Optional `(rowId, emoji) => Reactor[] \| undefined`: who reacted, in order, for the chip's tooltip ("Ada, You", `reactionTooltip`). Nothing supplies it yet: `ReactionSummary` has no reactor list (see "Needs"). Without it the tooltip says "You" when the viewer is the one reactor, and nothing otherwise. |
| `viewerId` | Optional: the viewer's user ID, so the tooltip says "You". |
| `renderContent` | Deprecated: the old single slot above the text, ignored when `content` is set. |

### Content slots

The row never imports the content views; it takes a source with two functions:

- `plan(message)` returns a `ContentPlan` or null: which slots have something (`above`, `below`, `outside`), whether the content **replaces the row's text** (`replacesText`, set when the message has rich blocks, which are a projection of `text`), and whether to draw **without the bubble** (`noBubble`: stickers and PNG photos without a caption, from chat-ui's `mediaModel`). The default, `planContent`, reads only row fields, is cached per row object and returns one interned object per combination.
- `render(message, slot, options)` draws one slot; the row calls it only for slots the plan marks. `options.highlightRanges` carries find ranges to the `above` slot when the content replaces the text.

| Slot | Where | Content sections (`CONTENT_SLOT_SECTIONS`) |
| --- | --- | --- |
| `above` | Inside the bubble, above the text | `forward`, `media`, `blocks` |
| `below` | Inside the bubble, under the text, before the time | `attachments` (link previews, task cards), `via` |
| `outside` | Under the bubble, on the bubble's side | `buttons`, `replies` |

With the content feature:

```tsx
const env = createContentEnv({ handlers, names })                       // once per list
const content = slottedContent((message, slot) => (
  <MessageContent message={message} env={env} sections={CONTENT_SLOT_SECTIONS[slot]} />
))
const context: MessageRowContext = { times, isDM, handlers, content }   // once per list
```

`CONTENT_SLOT_SECTIONS` holds constant arrays, so `MessageContent`'s memo keeps holding. When `replacesText` is set the row skips its own text (and its text memo), so a streaming block message re-renders the row's shell and the content's changed block, nothing else.

### Find in chat

`FindHighlights` (framework-free) holds the persistent find highlight: `showRow(rowId, ranges)` for the active match, `show(map)` for several rows, `clear()`. `rangesFor(rowId)` is a cached per-row computed that compares ranges by value, so when the active match moves only the row it left and the row it reached re-render; a new array with the same ranges re-renders nothing. Ranges are UTF-16 `[start, end)` into `message.text`; `normalizeRanges` clips, sorts and merges them, `findOccurrences` is a simple case-insensitive matcher (the lab's stand-in for the find controller).

The row passes its ranges to `MessageText` as `highlightRanges` (matched runs become `<mark data-kind="find">`, styled through `classNames.find`: solid orange with dark text in every bubble, theme and appearance, distinct from the translucent yellow `highlight` entity, and the system `Mark`/`MarkText` colors in forced colors). When the content replaces the text (rich blocks), the row passes them to the content instead, as `render(message, "above", { highlightRanges })`; every other slot call gets `{}`. The content side has to forward them to its blocks.

What a row shows (Mac `MessageView`, `MessageSizeCalculator`): others' messages at the inline start in the secondary bubble, your own at the inline end in the accent bubble; outside DMs others' rows keep an avatar column, the name on the first message of a run, the avatar at the bottom of the last; the tail on the last message of a run; emoji-only text without a reply, content or unsupported content has no bubble and renders at 64, 42 or 18 px for one, up to three, or more emoji. Inside the bubble, in order: the reply line, the `above` slot, the unsupported-content line, the text with the time beside its last line when it fits (else below, at the end; the `below` slot sits between the text and the time), then the reactions; the `outside` slot follows the bubble. A content plan with `noBubble` draws the row like an emoji-only message: no background, no tail, the time under the content. The time shows "edited" before it when `editDate` is set, and own messages have a fixed 12 px state glyph slot after it: a clock (sending), a check (sent), a red triangle (failed), and a dotted ring (uncertain, "Not confirmed yet"), which reads as neither failed nor delivered.

### `DaySeparatorRow`, `UnreadLineRow`, `LoadingOlderRow` (memoized)

- `DaySeparatorRow({ label, itemKey? })`: 34 px, label 12 px secondary, raised 4 px (Mac `DateSeparatorTableCell`). Pass `formatter.dayLabel(item.date).text`, prepared above the list.
- `UnreadLineRow({ label? = "Unread messages", itemKey? })`: 42 px, a 24 px tinted band (Mac `UnreadSeparatorTableCell`).
- `LoadingOlderRow({ loading, itemKey? })`: 34 px whether or not the spinner shows.

### Row actions

`new MessageActionsController({ actionsFor, label?, document?, menuKit? })`, one per list:

- `actionsFor(rowId)` returns the row's `MessageAction`s in menu order: `{ id, label, icon?, shortcut?, keyshortcuts?, enabled, destructive?, quick?, group?, run(invocation) }`. A menu item's accessible name is its label; `shortcut` is the visible hint (hidden from assistive technology) and `keyshortcuts` the `aria-keyshortcuts` value ("Meta+E"; derived from the hint by the kit's menu when omitted). Actions marked `quick` also show in the hover capsule; "More Actions" is always last there and opens the menu at the button. `group` changes put a separator in the menu. `run` gets `{ rowId, via: "quick" | "menu", anchor? }` (the button's rectangle for quick actions, to anchor an emoji picker). The command registry can supply these later.
- `list`: a part to attach to the list element or any ancestor of the rows (`useElement(controller.list)`). It tracks the hovered row and the row holding keyboard focus by delegated events, and opens the context menu on secondary click, the context menu key or Shift+F10. Links and editable fields keep the browser's menu.
- `isActive(rowId)`: a per-row signal, true while hovered, holding keyboard focus (`:focus-visible`), or with its menu open. A hover change re-renders the two rows involved.
- `openMenu(rowId, rect, { keyboard })`, `runQuick(rowId, action, rect)`, `setHovered`, `setFocused`, `dispose()`.
- **The menu loads on first use.** `contextMenu` is the kit's `LazyContextMenu`: rows and the list import none of the menu's code. The first secondary click (or the context menu key, Shift+F10, More Actions) loads the kit's menu chunk; the browser's menu is prevented at once and the menu opens where it would have when the code arrives (tested with a late loader in `actions.test.ts` and the kit). `warmMenu()` loads it ahead; the app should rather warm the shared chunk once (see the kit README, "Menus load on first use": `menus: () => import("@inline/ui/menu-kit")` in `view-chunks.ts` `chunkImporters` and `afterFirstPaint`). Measured on 17 November (analysis build, `bun run size`): signed in 248.5 kB before; the stub experiment on the menu view, menu controller and context menu controller gave 243.0 kB (5.5 kB); after the cut 243.1 kB, with the same stub on the new tree taking off only 0.3 kB (chunk layout), and the menu kit chunk 6.4 kB deferred. The trigger, `LazyContextMenu`, `Lazy` and `LazyMenuContent` that replace it on the first frame are about 1.5 kB of that.
- **Hover actions stay on the first frame.** The capsule (`QuickActions` and the action glyphs) measures about 1.1 kB gzip (`RowActions.tsx` 0.84 with the region and menu host, about half of `icons.tsx`'s 0.96); loading it on first hover would save that at the risk of a capsule that appears late under the pointer, so it stays.
- **Reaction picker anchor.** A quick action's `run` gets the button's rectangle (`invocation.anchor`). `setPickerAnchor(rowId, rect?)` when the app opens a reaction picker for a row and `setPickerAnchor(null)` when it closes: while set, the row stays active, so its capsule (the picker's anchor) stays on screen when the pointer moves into the picker; `pickerAnchor` is the signal. `reactionAnchor(rowId)` gives the rectangle for a picker opened from the menu or a command: the row's Add Reaction button (`data-quick-action="react"`) when shown, else its bubble (`data-message-bubble`), else the row; null when the row is not rendered.

`MessageActionsRegion({ controller, children, style? })` is a div with the part attached plus the menu; wrap the timeline's scroll container with it, not its content element. Or attach `controller.list` yourself and render `MessageActionsMenu({ controller })` once.

The menu is the UI kit's (`LazyContextMenu`, rendered by `MessageActionsMenu` as `LazyMenuContent`); the kit's menu items have no icons, so `icon` shows only in the capsule.

### Reaction chips

In order (`orderReactions`), each a toggle button: `aria-pressed` and the accent fill (the contrast fill in your own bubble) when you reacted (`ReactionSummary.mine`); `onReactionClick(rowId, reaction)` decides add or remove from `reaction.mine`. The accessible name is `reactionChipLabel` from the emoji feature's light half (`features/emoji/display.ts`, imported alone): "thumbs up, 3, including you" once `context.emojiEngine` has the data. The emoji and count spans are hidden from assistive technology, so the name is read once. Tooltip: `reactionChipTooltip(reaction, reactors, viewerId)` (native `title`).

## Helpers (framework-free, unit-tested)

| Export | What |
| --- | --- |
| `orderReactions(reactions)` | By count, highest first, then by emoji in code point order (Mac `ReactionChipOrdering`). Cached per array. `reactionChipTooltip(reaction, reactors?, viewerId?)` is a chip's tooltip; `reactionLabel` the old name without emoji names (kept for callers). |
| `statePresentation(state, out)` | The glyph, label and tone for an own message; undefined for others'. Unknown states read as uncertain. |
| `MessageTextMemo`, `createMessageTextMemo()` | The per-row text memo: `read(row)` returns the same `{ document, emoji }` while the text and entities are unchanged, and feeds `updateTextDocument` when they change, so streaming keeps every unchanged node's identity. Keyed by `row.id`. |
| `emojiSize(text)` | `none`, `single`, `few` or `many`, by the Mac's emoji rules. |
| `FindHighlights`, `normalizeRanges`, `findOccurrences`, `sameRanges` | Find in chat (see "Find in chat"). |
| `planContent(row)`, `slottedContent(render, plan?)`, `CONTENT_SLOT_SECTIONS`, `CONTENT_SLOTS` | The content plan and source (see "Content slots"). |
| `rowLayout(input)` | Which parts a row shows (side, bubble kind, name, avatar, tail, emoji size) and the two directions: `rowDir` (the interface's, or inherit) and `textDir` (the text's, for the text container only). The side never depends on the text's direction (tested over every combination). |
| `presentSender(user)`, `presentReply(messageId, replied, sender)`, `createMessageTimes(formatter)` | Prepared row data, cached by input identity. |

## Rules a caller keeps, so rows stay pure

1. **Stable props.** Create `context` (and its `handlers`) once above the list. Get `sender` and `reply` from the cached helpers, not fresh literals. A new object in any prop re-renders the row.
2. **Prepared data only.** No store reads, measurement or date formatting in a row: the time comes from `context.times`, labels from the formatter above the list, names and colors from `presentSender`.
3. **Rows from a list are memoized.** These components are wrapped in `memo`; if you wrap them, wrap that component in `memo` too (the React Compiler does not stop a list re-render from re-running row bodies).
4. **No vertical margins.** Rows carry their spacing inside (1 px between rows, 8 px above the first of a run), as the timeline's compensation requires. Do not add margins around them.
5. **Streaming.** Hand the row each new `MessageRow` (coalesced to one per frame by the reactive scheduler); its memo and `updateTextDocument` re-render only the growing paragraph.
6. **Direction.** Never put a message's direction (`dirAttribute`, `TextDocument.dir`) on a row or anything around it, and never `dir="auto"` on the list or its content element: `dir="auto"` resolves from the first strong letter of everything inside, so one Arabic message would mirror the whole list. A row's side comes from `message.out` in the interface direction (incoming at the inline start, outgoing at the inline end); the avatar, name, bubble, tail, time, reactions, reply line, quick actions and separators all follow the interface. The text's direction goes on the text container inside the bubble only (`rowLayout(...).textDir`); the sender name and reply text are `<bdi>` isolates, so they keep their glyph order while aligning with the interface. Mac: `MessageView` places the avatar and bubble by `outgoing` alone.
7. **`content-visibility` is not used on rows**: it breaks find in page and the timeline's anchoring. Do not add it.
8. **Content reserves its size.** Whatever the slots render has its final box in the first frame.

## Check in a real browser

None of the following can be checked in Node; the lab is the place:

- Layout: time beside the last line when it fits, below otherwise; long words and long links wrap; code blocks scroll sideways inside the block only, with no page-level horizontal scroll; the bubble tail joins the bubble cleanly in light, dark, both directions and at 1x and 2x.
- No layout shift: hovering a row, the capsule appearing, a state glyph changing, a reaction toggling only changes the row it belongs to.
- Render counts (lab "Render counts"): a reaction, a flash or a streaming update renders exactly one row; hovering renders the rows entering and leaving hover; toggling the theme or direction renders none.
- The flash plays once per highlight, restarts on a second jump to the same row, and under reduced motion shows a tint that disappears without fading.
- Keyboard: Tab into a message's link shows its quick actions; Tab reaches them; the context menu key and Shift+F10 open the menu with the first item highlighted; Escape returns focus.
- Secondary click on a link shows the browser's menu; elsewhere on a message, ours.
- Text selection across several rows selects message text only (names, times, reactions and the capsule are not selectable).
- Forced colors (Windows high contrast) and `prefers-contrast: more`: bubbles get outlines, the outgoing bubble darkens, the time gets stronger.
- Right to left: own messages on the left, tails mirrored, Persian text right-aligned inside bubbles, mixed text by majority.
- Find (lab header): type "deploy", step with Enter or the arrows. The active row's matches are orange with dark text in incoming and outgoing bubbles, light and dark; with render counts on, only the two rows involved render per step; Windows high contrast shows the system highlight. A match in the rich-block message reaches the content slot, which draws it only once the content forwards `highlightRanges`.
- Lab "Content" section: the photo's caption is under the photo inside the bubble; the link preview and "Sent via" are under the text and above the time; the buttons and "4 replies" are under the bubble on its side; the sticker and the PNG have no bubble or tail; the block message shows its text once.
- Lab "Direction" section: the same Arabic and English rows in a left-to-right and a right-to-left panel. In the left-to-right panel Layla's Arabic messages, avatar and name sit on the left with right-aligned text inside the bubble; in the right-to-left panel English rows from others sit on the right.

## Needs

- **Who reacted.** `ReactionSummary` is `{ emoji, count, mine }`. The chip tooltip (the Mac's "Ada, You") needs the reactors: `ReactionSummary.userIds?: UserID[]` in reaction order (the core already groups `message.reactions` by emoji with the user IDs, `client/src/queries/rows.ts` `reactionSummaries`; a bound such as the first 20 is enough for a tooltip), and their user rows in the `chatWindow` subscription (or a `user` row lookup), so the view can build `Reactor { userId, name }`. Then pass `reactorsFor` in the context.
