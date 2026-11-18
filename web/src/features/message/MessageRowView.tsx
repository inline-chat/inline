/**
 * One message in the timeline, in the Mac app's default (bubble) style.
 * Pure: everything it shows comes in through props; it reads no store. A row
 * may instead be given its row signal (`MessageRowSignalView`), so a change
 * to one message re-renders that one row.
 *
 * Rules a caller keeps (README.md): stable `context` (create it once above
 * the list), presentation objects from the cached helpers in
 * `presentation.ts`, and no vertical margins around rows.
 */

import * as stylex from "@stylexjs/stylex"
import type { MessageRow, MessageRowId, ReactionSummary } from "@inline/core-protocol"
import type { MessageID, UserID } from "@inline/ids"
import { type ReadSignal, signal } from "@inline/reactive"
import { useSignal } from "@inline/reactive/react"
import { type MessageTextClassNames, type MessageTextHandlers, MessageText } from "@inline/chat-ui/react"
import { Avatar } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, type ReactNode, useState } from "react"
import type { MessageActionsController } from "./actions"
import type { ContentRenderOptions, MessageRowContentSource } from "./content-slots"
import type { FindRanges } from "./find"
import { StateIcon } from "./icons"
import { type BubbleKind, rowLayout } from "./layout"
import type { MessageTimes, ReplyPresentation, SenderPresentation } from "./presentation"
import { reactionChipLabel, type Reactor } from "../emoji/display"
import type { EmojiEngine } from "../emoji/engine"
import { orderReactions, reactionChipTooltip } from "./reactions"
import { QuickActions } from "./RowActions"
import { statePresentation } from "./state"
import { createMessageTextMemo } from "./text-memo"

// ---------------------------------------------------------------------------
// Props

export type MessageRowHandlers = MessageTextHandlers & {
  /** The reply line was activated: jump to the replied-to message. */
  readonly onReplyClick?: (rowId: MessageRowId, messageId: MessageID) => void
  /** A reaction chip was activated. `reaction.mine` says whether this removes or adds. */
  readonly onReactionClick?: (rowId: MessageRowId, reaction: ReactionSummary) => void
  /** The sender's name was clicked. */
  readonly onSenderClick?: (userId: UserID) => void
}

/**
 * What every row of one list shares. Create it once above the list and keep
 * its identity: a new context re-renders every row.
 */
export type MessageRowContext = {
  readonly times: MessageTimes
  /** A direct message chat: no names or avatars. */
  readonly isDM: boolean
  /**
   * The interface direction. When set, each row writes it as its own `dir`,
   * so no ancestor (a `dir="auto"` container, say) can make a row follow its
   * message's text. Rows never take the text's direction either way.
   */
  readonly interfaceDir?: "ltr" | "rtl"
  readonly handlers: MessageRowHandlers
  /** Hover and focus quick actions and the context menu. Without it, rows show neither. */
  readonly actions?: MessageActionsController
  /**
   * Everything beyond the text (media, rich blocks, link previews, "Sent
   * via", bot buttons, the reply summary), in three slots: `above` and
   * `below` the text inside the bubble, and `outside` under it. Build it with
   * `slottedContent(render)` and keep its identity. Its plan can replace the
   * row's text (rich blocks) and drop the bubble (stickers). Content must have
   * its final size in the first frame (`timeline-and-composer.md`, "Media in
   * the timeline").
   */
  readonly content?: MessageRowContentSource<ReactNode>
  /**
   * Find in chat: a per-row signal of UTF-16 `[start, end)` ranges into the
   * message text to mark persistently, or undefined for rows that can never
   * have one. Use `FindHighlights.rangesFor`: rows without a match read
   * undefined and do not re-render when the active match moves.
   */
  readonly highlightRangesFor?: (rowId: MessageRowId) => ReadSignal<FindRanges | undefined> | undefined
  /**
   * Emoji names for the reaction chips' accessible names ("thumbs up, 3,
   * including you"): the emoji feature's `services.loader.engine`. Until it
   * has loaded, or without it, a chip is named by its emoji. Shared by all
   * rows: its one change (the data arriving) re-renders the rows with reactions.
   */
  readonly emojiEngine?: ReadSignal<EmojiEngine | undefined>
  /**
   * Who reacted with `emoji`, in order, for the chip's tooltip ("Ada, You").
   * TODO(contract): `ReactionSummary` carries no reactors yet; until it does
   * the tooltip says "You" only when the viewer is the one reactor.
   */
  readonly reactorsFor?: (rowId: MessageRowId, emoji: string) => readonly Reactor[] | undefined
  /** The viewer's user ID, so the tooltip says "You". */
  readonly viewerId?: string
  /**
   * @deprecated The first, single slot (inside the bubble above the text).
   * Use `content`; kept so existing callers compile. Ignored when `content` is set.
   */
  readonly renderContent?: (message: MessageRow) => ReactNode
}

export type MessageRowViewProps = {
  readonly message: MessageRow
  /** First message of a sender run (shows the name). */
  readonly firstInGroup: boolean
  /** Last message of a sender run (shows the avatar and the tail). */
  readonly lastInGroup: boolean
  readonly context: MessageRowContext
  /** The sender, from `presentSender`. Needed for others' messages in group chats. */
  readonly sender?: SenderPresentation
  /** The reply line, from `presentReply`, when `message.replyToMessageId` is set. */
  readonly reply?: ReplyPresentation
  /** Flash the row once ("jumped to this message"). Pass a new number for each flash; undefined for none. */
  readonly highlight?: number
  /** The timeline item key, written as `data-timeline-key`. */
  readonly itemKey?: string
  /**
   * Set by the list's keyboard navigation (0 on the row holding the roving
   * tab stop, -1 on the others). Rows are not focusable by default, so a
   * click never focuses (or scrolls to) a row.
   */
  readonly tabIndex?: number
}

const inactive: ReadSignal<boolean> = signal(false)
const noRanges: ReadSignal<FindRanges | undefined> = signal<FindRanges | undefined>(undefined)
const noOptions: ContentRenderOptions = {}


// ---------------------------------------------------------------------------
// Row

/** A message row. Memoized: it renders again only when one of its props changes identity. */
export const MessageRowView = memo(function MessageRowView(props: MessageRowViewProps) {
  const { message, context } = props
  const [textMemo] = useState(createMessageTextMemo)
  const active = useSignal(context.actions ? context.actions.isActive(message.id) : inactive)
  const findRanges = useSignal(context.highlightRangesFor?.(message.id) ?? noRanges)

  const source = context.content
  const plan = source ? source.plan(message) : null
  const legacyNode = !source && context.renderContent ? context.renderContent(message) : null
  const legacy = legacyNode === undefined || legacyNode === false ? null : legacyNode
  // Rich blocks are the text: the content draws it, the row does not.
  const text = plan?.replacesText ? null : textMemo.read(message)
  const hasReply = message.replyToMessageId !== undefined
  const unsupported = message.hasUnsupportedContent === true
  const hasText = text !== null && text.document.blocks.length > 0
  const layout = rowLayout({
    out: message.out,
    isDM: context.isDM,
    firstInGroup: props.firstInGroup,
    lastInGroup: props.lastInGroup,
    emoji: text?.emoji ?? "none",
    hasExtras: hasReply || plan !== null || legacy !== null || unsupported,
    noBubble: plan?.noBubble === true,
    textDir: text?.document.dir,
    interfaceDir: context.interfaceDir,
  })
  // Rich blocks draw the text, so they get the find ranges; otherwise the row's text does.
  const aboveOptions = plan?.replacesText && findRanges ? { highlightRanges: findRanges } : noOptions
  const above = source && plan?.above ? source.render(message, "above", aboveOptions) : legacy
  const below = source && plan?.below ? source.render(message, "below", noOptions) : null
  const outside = source && plan?.outside ? source.render(message, "outside", noOptions) : null
  const bubble = layout.bubble
  const reactions = orderReactions(message.reactions)
  const sender = props.sender
  const flash = props.highlight === undefined ? null : props.highlight % 2 === 0 ? styles.flashEven : styles.flashOdd

  return (
    <div
      data-message-row={message.id}
      data-timeline-key={props.itemKey}
      dir={layout.rowDir}
      data-state={message.state}
      tabIndex={props.tabIndex}
      {...stylex.props(styles.row, props.firstInGroup && styles.rowFirst, flash)}
    >
      {layout.reserveAvatar && (
        <div {...stylex.props(styles.avatarColumn)}>
          {layout.showAvatar && sender && (
            <Avatar name={sender.fullName} seed={sender.seed} src={sender.photoUrl} size="regular" />
          )}
        </div>
      )}
      <div {...stylex.props(styles.column, layout.side === "end" && styles.columnEnd)}>
        {layout.showName && sender && (
          <SenderName sender={sender} onClick={context.handlers.onSenderClick} />
        )}
        <div
          data-message-bubble=""
          {...stylex.props(
            styles.bubble,
            bubbleStyles[bubble],
            layout.tail && (layout.side === "end" ? styles.tailCornerEnd : styles.tailCornerStart),
          )}
        >
          {hasReply && (
            <ReplyLine
              rowId={message.id}
              reply={props.reply}
              fallbackId={message.replyToMessageId}
              bubble={bubble}
              onClick={context.handlers.onReplyClick}
            />
          )}
          {above !== null && <div {...stylex.props(styles.slotAbove)}>{above}</div>}
          {unsupported && (
            <p {...stylex.props(styles.unsupported, bubble === "outgoing" && styles.unsupportedOutgoing)}>
              This message has content this version of Inline can’t show.
            </p>
          )}
          <div {...stylex.props(styles.body, bubble === "none" && styles.bodyPlain)}>
            {text !== null && hasText && (
              // The message's direction applies here and nowhere above: the row,
              // avatar, name, bubble, time and reactions follow the interface.
              <div dir={layout.textDir} {...stylex.props(styles.text, emojiStyles[layout.emoji])}>
                <MessageText
                  document={text.document}
                  highlightRanges={findRanges}
                  classNames={bubble === "outgoing" ? outgoingTextClasses : textClasses}
                  onMention={context.handlers.onMention}
                  onThreadRef={context.handlers.onThreadRef}
                  onBotCommand={context.handlers.onBotCommand}
                  onAppLink={context.handlers.onAppLink}
                  onExternalLink={context.handlers.onExternalLink}
                />
              </div>
            )}
            {/* Link previews and "Sent via": their own line, then the time at the end. */}
            {below !== null && <div {...stylex.props(styles.slotBelow, hasText && styles.slotBelowAfterText)}>{below}</div>}
            <Meta message={message} times={context.times} bubble={bubble} />
          </div>
          {reactions.length > 0 && (
            <Reactions rowId={message.id} reactions={reactions} bubble={bubble} context={context} />
          )}
          {layout.tail && <Tail side={layout.side} bubble={bubble} />}
        </div>
        {/* Bot buttons and the reply thread summary, under the bubble. */}
        {outside !== null && <div {...stylex.props(styles.slotOutside)}>{outside}</div>}
      </div>
      {active && context.actions && <QuickActions rowId={message.id} controller={context.actions} />}
    </div>
  )
})

/**
 * A row bound to its row signal: a change to this message re-renders this
 * row only, and a change to the list re-renders no rows. Renders nothing
 * while the row is missing.
 */
export const MessageRowSignalView = memo(function MessageRowSignalView(
  props: Omit<MessageRowViewProps, "message"> & { readonly row: ReadSignal<MessageRow | undefined> },
) {
  const message = useSignal(props.row)
  if (!message) return null
  return (
    <MessageRowView
      message={message}
      firstInGroup={props.firstInGroup}
      lastInGroup={props.lastInGroup}
      context={props.context}
      sender={props.sender}
      reply={props.reply}
      highlight={props.highlight}
      itemKey={props.itemKey}
      tabIndex={props.tabIndex}
    />
  )
})

// ---------------------------------------------------------------------------
// Parts

function SenderName(props: { sender: SenderPresentation; onClick: ((userId: UserID) => void) | undefined }) {
  const { sender, onClick } = props
  return (
    <span
      {...stylex.props(styles.name, dynamic.nameColor(sender.color), onClick && styles.nameClickable)}
      onClick={onClick ? () => onClick(sender.userId) : undefined}
    >
      {/* The name keeps its own glyph order; its place follows the interface. */}
      <bdi>{sender.name}</bdi>
    </span>
  )
}

function Meta(props: { message: MessageRow; times: MessageTimes; bubble: BubbleKind }) {
  const { message, times, bubble } = props
  const state = statePresentation(message.state, message.out)
  return (
    <span
      {...stylex.props(styles.meta, metaTones[bubble])}
      onPointerEnter={(event) => {
        // The tooltip is formatted on first hover, not while rendering.
        if (!event.currentTarget.title) event.currentTarget.title = times.tooltip(message.date)
      }}
    >
      {message.editDate !== undefined && <span {...stylex.props(styles.edited)}>edited</span>}
      <span>{times.time(message.date)}</span>
      {state && (
        <span
          role="img"
          aria-label={state.label}
          title={state.label}
          data-glyph={state.glyph}
          {...stylex.props(styles.glyph, state.tone === "danger" && styles.glyphDanger)}
        >
          <StateIcon glyph={state.glyph} />
        </span>
      )}
    </span>
  )
}

function ReplyLine(props: {
  rowId: MessageRowId
  reply: ReplyPresentation | undefined
  fallbackId: MessageID | undefined
  bubble: BubbleKind
  onClick: MessageRowHandlers["onReplyClick"]
}) {
  const { reply, onClick, rowId } = props
  const target = reply?.messageId ?? props.fallbackId
  const outgoing = props.bubble === "outgoing"
  const accent = outgoing ? "#ffffff" : (reply?.color ?? color.accent)
  return (
    <button
      type="button"
      disabled={!onClick || target === undefined}
      onClick={onClick && target !== undefined ? () => onClick(rowId, target) : undefined}
      {...stylex.props(styles.reply, outgoing ? styles.replyOutgoing : dynamic.replyTint(accent))}
    >
      <span aria-hidden="true" {...stylex.props(styles.replyBar, dynamic.background(accent))} />
      <span {...stylex.props(styles.replyLines)}>
        <span {...stylex.props(styles.replyName, dynamic.color(accent))}>
          <bdi>{reply?.senderName ?? "Reply"}</bdi>
        </span>
        {/* Isolated, not `dir`: the quoted text keeps its glyph order but aligns with the interface. */}
        <span {...stylex.props(styles.replyText, reply?.missing !== false && styles.replyMissing)}>
          <bdi>{reply?.text ?? "Original message"}</bdi>
        </span>
      </span>
    </button>
  )
}

function Reactions(props: {
  rowId: MessageRowId
  reactions: readonly ReactionSummary[]
  bubble: BubbleKind
  context: MessageRowContext
}) {
  const { rowId, context } = props
  const onClick = context.handlers.onReactionClick
  const engine = useSignal(context.emojiEngine ?? noEngine)
  const outgoing = props.bubble === "outgoing"
  return (
    <div role="group" aria-label="Reactions" {...stylex.props(styles.reactions, props.bubble === "none" && styles.reactionsPlain)}>
      {props.reactions.map((reaction) => (
        <button
          key={reaction.emoji}
          type="button"
          // "You reacted": pressed, and drawn in the accent (or the outgoing bubble's contrast) fill.
          aria-pressed={reaction.mine}
          aria-label={reactionChipLabel(reaction, engine)}
          title={reactionChipTooltip(reaction, context.reactorsFor?.(rowId, reaction.emoji), context.viewerId)}
          data-mine={reaction.mine || undefined}
          onClick={onClick ? () => onClick(rowId, reaction) : undefined}
          {...stylex.props(
            styles.chip,
            outgoing
              ? reaction.mine
                ? styles.chipOutgoingMine
                : styles.chipOutgoing
              : reaction.mine
                ? styles.chipMine
                : styles.chipIncoming,
          )}
        >
          <span aria-hidden="true" {...stylex.props(styles.chipEmoji)}>
            {reaction.emoji}
          </span>
          <span aria-hidden="true" {...stylex.props(styles.chipCount)}>
            {reaction.count}
          </span>
        </button>
      ))}
    </div>
  )
}

const noEngine: ReadSignal<EmojiEngine | undefined> = signal<EmojiEngine | undefined>(undefined)

/** The bubble's tail at its bottom corner (Mac `MessageBubbleTailView`), mirrored per side and direction. */
function Tail(props: { side: "start" | "end"; bubble: BubbleKind }) {
  return (
    <svg
      width="20"
      height="15"
      viewBox="0 0 20 15"
      aria-hidden="true"
      focusable="false"
      {...stylex.props(
        styles.tail,
        props.side === "end" ? styles.tailEnd : styles.tailStart,
        props.bubble === "outgoing" ? styles.tailOutgoing : styles.tailIncoming,
      )}
    >
      <path d="M0 0H14V6C14 10.5 16.2 13.4 20 15C15.6 15.4 11.4 14.6 8.4 12.6C6.4 13.8 3.8 14.3 0 14Z" fill="currentColor" />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Styles

const BUBBLE_INSET_INLINE = "11px" // Theme.messageBubbleContentHorizontalInset
const BUBBLE_INSET_BLOCK = "6px" // Theme.messageTextOnlyVerticalInsets
const SIDE_PADDING = "16px" // Theme.messageSidePadding
const SAFE_AREA = "50px" // Theme.messageRowSafeAreaInset
const MAX_TEXT_WIDTH = "420px" // Theme.messageMaxWidth
const GROUP_SPACING = "8px" // Theme.messageGroupSpacing
const ROW_GAP = "1px" // Theme.messageOuterVerticalPadding
const AVATAR_GAP = "8px" // Theme.messageHorizontalStackSpacing

// Two keyframes that look the same but differ in text (StyleX names keyframes
// by content): alternating between them restarts the animation for each new
// highlight without remounting the row.
const flashOdd = stylex.keyframes({
  "0%": { backgroundColor: `color-mix(in srgb, ${color.accent} 20%, transparent)` },
  "70%": { backgroundColor: `color-mix(in srgb, ${color.accent} 20%, transparent)` },
  "100%": { backgroundColor: "transparent" },
})
const flashEven = stylex.keyframes({
  "0%": { backgroundColor: `color-mix(in srgb, ${color.accent} 20%, transparent)` },
  "70%": { backgroundColor: `color-mix(in srgb, ${color.accent} 20%, transparent)` },
  "100%": { backgroundColor: "rgb(0 0 0 / 0)" },
})

const styles = stylex.create({
  row: {
    position: "relative",
    display: "flex",
    alignItems: "stretch",
    paddingInline: SIDE_PADDING,
    paddingBlock: ROW_GAP,
    boxSizing: "border-box",
    outline: {
      default: "none",
      ":focus-visible": `2px solid ${color.focusRing}`,
    },
    outlineOffset: "-2px",
  },
  rowFirst: { paddingBlockStart: GROUP_SPACING },
  flashOdd: {
    animationName: flashOdd,
    animationDuration: "1.6s",
    animationTimingFunction: { default: "ease-out", "@media (prefers-reduced-motion: reduce)": "step-end" },
  },
  flashEven: {
    animationName: flashEven,
    animationDuration: "1.6s",
    animationTimingFunction: { default: "ease-out", "@media (prefers-reduced-motion: reduce)": "step-end" },
  },
  avatarColumn: {
    display: "flex",
    alignItems: "flex-end",
    flexShrink: 0,
    inlineSize: size.avatar,
    marginInlineEnd: AVATAR_GAP,
    userSelect: "none",
  },
  column: {
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
    flexGrow: 1,
    minInlineSize: 0,
  },
  columnEnd: { alignItems: "flex-end" },
  name: {
    display: "block",
    maxInlineSize: "100%",
    blockSize: "16px",
    paddingInlineStart: "5px",
    boxSizing: "border-box",
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
    lineHeight: "16px",
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
    userSelect: "none",
  },
  nameClickable: { cursor: "pointer" },
  bubble: {
    position: "relative",
    display: "flex",
    flexDirection: "column",
    inlineSize: "fit-content",
    maxInlineSize: `min(calc(${MAX_TEXT_WIDTH} + 2 * ${BUBBLE_INSET_INLINE}), calc(100% - ${SAFE_AREA}))`,
    minInlineSize: 0,
    boxSizing: "border-box",
    paddingInline: BUBBLE_INSET_INLINE,
    paddingBlock: BUBBLE_INSET_BLOCK,
    borderRadius: radius.bubble,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
    // Invisible normally; drawn in forced colors, where backgrounds are dropped.
    outline: "1px solid transparent",
    outlineOffset: "-1px",
  },
  tailCornerEnd: { borderEndEndRadius: 0 },
  tailCornerStart: { borderEndStartRadius: 0 },
  slotAbove: { marginBlockEnd: space.xs, minInlineSize: 0, maxInlineSize: "100%" },
  slotBelow: { flexBasis: "100%", minInlineSize: 0 },
  slotBelowAfterText: { marginBlockStart: space.xs },
  slotOutside: {
    marginBlockStart: space.xs,
    minInlineSize: 0,
    maxInlineSize: `min(calc(${MAX_TEXT_WIDTH} + 2 * ${BUBBLE_INSET_INLINE}), calc(100% - ${SAFE_AREA}))`,
  },
  unsupported: {
    marginBlock: 0,
    marginBlockEnd: space.xxs,
    fontStyle: "italic",
    color: color.secondaryLabel,
  },
  unsupportedOutgoing: { color: "rgb(255 255 255 / 0.75)" },
  body: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "flex-end",
    columnGap: space.md,
    minInlineSize: 0,
  },
  bodyPlain: { flexDirection: "column", alignItems: "flex-end" },
  text: {
    flexGrow: 1,
    flexShrink: 1,
    flexBasis: "auto",
    minInlineSize: 0,
  },
  meta: {
    display: "inline-flex",
    alignItems: "center",
    gap: "3px",
    flexShrink: 0,
    marginInlineStart: "auto",
    blockSize: "13px",
    marginBlockStart: "2px",
    fontSize: "10px",
    lineHeight: "13px",
    fontVariantNumeric: "tabular-nums",
    whiteSpace: "nowrap",
    userSelect: "none",
    cursor: "default",
  },
  edited: { fontStyle: "italic" },
  glyph: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: "12px",
    blockSize: "12px",
    flexShrink: 0,
  },
  glyphDanger: { color: color.destructive },
  reply: {
    display: "flex",
    alignItems: "stretch",
    gap: "6px",
    alignSelf: "stretch",
    minInlineSize: 0,
    blockSize: "34px",
    marginBlockEnd: space.xs,
    paddingBlock: space.xs,
    paddingInline: space.sm,
    boxSizing: "border-box",
    borderStyle: "none",
    borderRadius: radius.control,
    fontFamily: "inherit",
    fontSize: font.sizeCallout,
    lineHeight: "13px",
    textAlign: "start",
    color: color.label,
    cursor: { default: "pointer", ":disabled": "default" },
    userSelect: "none",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  replyOutgoing: {
    backgroundColor: "rgb(255 255 255 / 0.12)",
    color: "#ffffff",
  },
  replyBar: {
    flexShrink: 0,
    inlineSize: "3px",
    borderRadius: "2px",
  },
  replyLines: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    minInlineSize: 0,
  },
  replyName: {
    fontWeight: font.weightSemibold,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  replyText: {
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  replyMissing: { opacity: 0.7, fontStyle: "italic" },
  reactions: {
    display: "flex",
    flexWrap: "wrap",
    gap: space.xs,
    marginBlockStart: space.sm,
    userSelect: "none",
  },
  reactionsPlain: { marginBlockStart: "3px" },
  chip: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.xxs,
    blockSize: "26px",
    paddingInlineStart: space.xs,
    paddingInlineEnd: space.sm,
    boxSizing: "border-box",
    borderStyle: "none",
    borderRadius: radius.pill,
    fontFamily: "inherit",
    cursor: "pointer",
    outline: { default: "1px solid transparent", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: { default: "-1px", ":focus-visible": "1px" },
  },
  chipEmoji: { fontSize: "14px", lineHeight: 1 },
  chipCount: { fontSize: font.sizeCallout, fontVariantNumeric: "tabular-nums", lineHeight: 1 },
  chipIncoming: {
    backgroundColor: {
      default: `color-mix(in srgb, ${color.accent} 20%, transparent)`,
      ":hover": `color-mix(in srgb, ${color.accent} 28%, transparent)`,
    },
    color: color.accent,
  },
  chipMine: { backgroundColor: color.accent, color: color.onAccent },
  chipOutgoing: {
    backgroundColor: { default: "rgb(255 255 255 / 0.2)", ":hover": "rgb(255 255 255 / 0.28)" },
    color: "#ffffff",
  },
  chipOutgoingMine: { backgroundColor: "#ffffff", color: color.accent },
  tail: {
    position: "absolute",
    insetBlockEnd: "-1px",
    pointerEvents: "none",
    display: { default: "block", "@media (forced-colors: active)": "none" },
  },
  tailEnd: {
    insetInlineEnd: "-6px",
    transform: { default: null, ":dir(rtl)": "scaleX(-1)" },
  },
  tailStart: {
    insetInlineStart: "-6px",
    transform: { default: "scaleX(-1)", ":dir(rtl)": null },
  },
  tailIncoming: { color: color.secondaryBubble },
  tailOutgoing: { color: { default: color.bubble, "@media (prefers-contrast: more)": color.selectedContentBackground } },
})

const bubbleStyles = stylex.create({
  incoming: {
    backgroundColor: color.secondaryBubble,
    color: color.secondaryBubbleText,
    outline: {
      default: "1px solid transparent",
      "@media (prefers-contrast: more)": `1px solid ${color.separator}`,
    },
  },
  outgoing: {
    // The accent bubble is light for white text; more contrast darkens it.
    backgroundColor: { default: color.bubble, "@media (prefers-contrast: more)": color.selectedContentBackground },
    color: "#ffffff",
  },
  none: {
    paddingInline: 0,
    paddingBlock: 0,
    backgroundColor: "transparent",
    color: color.label,
  },
})

// Mac: tertiaryLabelColor, white at 70% in the accent bubble.
const metaTones = stylex.create({
  incoming: { color: { default: color.tertiaryLabel, "@media (prefers-contrast: more)": color.secondaryLabel } },
  outgoing: { color: { default: "rgb(255 255 255 / 0.7)", "@media (prefers-contrast: more)": "#ffffff" } },
  none: { color: { default: color.tertiaryLabel, "@media (prefers-contrast: more)": color.secondaryLabel } },
})

const emojiStyles = stylex.create({
  none: {},
  // MessageTextTypography.fontSize: 64, 42 and 18 pt.
  single: { fontSize: "64px", lineHeight: 1.15 },
  few: { fontSize: "42px", lineHeight: 1.15 },
  many: { fontSize: "18px", lineHeight: 1.3 },
})

const dynamic = stylex.create({
  nameColor: (value: string) => ({ color: value }),
  color: (value: string) => ({ color: value }),
  background: (value: string) => ({ backgroundColor: value }),
  /** The reply line's tint and text color in an incoming bubble. */
  replyTint: (value: string) => ({
    backgroundColor: `color-mix(in srgb, ${value} 8%, transparent)`,
  }),
})

// Text: class names for MessageText, one set per bubble kind, built once.

const text = stylex.create({
  root: { minInlineSize: 0, overflowWrap: "anywhere" },
  paragraph: {
    marginInline: 0,
    marginBlockEnd: 0,
    marginBlockStart: { default: "0.5em", ":first-child": 0 },
    whiteSpace: "pre-wrap",
    overflowWrap: "anywhere",
  },
  codeBlock: {
    marginInline: 0,
    marginBlockEnd: 0,
    marginBlockStart: { default: "0.5em", ":first-child": 0 },
    maxInlineSize: "100%",
    overflowX: "auto",
    paddingBlock: space.sm,
    paddingInline: space.md,
    boxSizing: "border-box",
    borderRadius: radius.control,
    backgroundColor: "light-dark(rgb(0 0 0 / 0.05), rgb(255 255 255 / 0.07))",
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    lineHeight: 1.45,
    whiteSpace: "pre",
    overflowWrap: "normal",
    scrollbarWidth: "thin",
  },
  quote: {
    marginInline: 0,
    marginBlockEnd: 0,
    marginBlockStart: { default: "0.5em", ":first-child": 0 },
    paddingInlineStart: space.md,
    borderInlineStartWidth: "3px",
    borderInlineStartStyle: "solid",
    borderInlineStartColor: color.accent,
  },
  mathBlock: {
    display: "block",
    marginBlockStart: { default: "0.5em", ":first-child": 0 },
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    whiteSpace: "pre-wrap",
  },
  link: {
    color: color.link,
    textDecoration: { default: "none", ":hover": "underline" },
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  mention: {
    color: color.link,
    fontWeight: font.weightMedium,
    cursor: "pointer",
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  threadRef: {
    color: color.link,
    cursor: "pointer",
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  botCommand: {
    color: color.link,
    cursor: "pointer",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  math: { fontFamily: font.familyMono, fontSize: "0.92em" },
  code: {
    paddingInline: "3px",
    borderRadius: radius.small,
    backgroundColor: "light-dark(rgb(0 0 0 / 0.06), rgb(255 255 255 / 0.1))",
    fontFamily: font.familyMono,
    fontSize: "0.92em",
  },
  highlight: {
    color: "inherit",
    borderRadius: "2px",
    backgroundColor: `color-mix(in srgb, ${color.yellow} 45%, transparent)`,
  },
  // Find in chat: solid orange with dark text, so it reads the same on every
  // bubble, theme and appearance, and differs from the translucent yellow of
  // the `highlight` entity. Forced colors use the system's Mark colors.
  find: {
    color: { default: "#1d1d1f", "@media (forced-colors: active)": "MarkText" },
    backgroundColor: { default: color.orange, "@media (forced-colors: active)": "Mark" },
    borderRadius: "3px",
    boxShadow: `0 0 0 1px ${color.orange}`,
    outline: { default: null, "@media (forced-colors: active)": "1px solid MarkText" },
    forcedColorAdjust: "none",
    boxDecorationBreak: "clone",
    WebkitBoxDecorationBreak: "clone",
  },
})

const outgoingText = stylex.create({
  codeBlock: { backgroundColor: "rgb(255 255 255 / 0.15)" },
  quote: { borderInlineStartColor: "rgb(255 255 255 / 0.7)" },
  link: { color: "inherit", textDecoration: "underline" },
  mention: { color: "inherit", fontWeight: font.weightSemibold },
  threadRef: { color: "inherit", textDecoration: "underline" },
  botCommand: { color: "inherit", textDecoration: "underline" },
  code: { backgroundColor: "rgb(255 255 255 / 0.18)" },
  highlight: { backgroundColor: "rgb(255 255 255 / 0.3)" },
})

const className = (...parts: stylex.StyleXStyles[]): string | undefined => stylex.props(...parts).className

const textClasses: MessageTextClassNames = {
  root: className(text.root),
  paragraph: className(text.paragraph),
  codeBlock: className(text.codeBlock),
  quote: className(text.quote),
  mathBlock: className(text.mathBlock),
  link: className(text.link),
  mention: className(text.mention),
  threadRef: className(text.threadRef),
  botCommand: className(text.botCommand),
  math: className(text.math),
  code: className(text.code),
  highlight: className(text.highlight),
  find: className(text.find),
}

const outgoingTextClasses: MessageTextClassNames = {
  ...textClasses,
  codeBlock: className(text.codeBlock, outgoingText.codeBlock),
  quote: className(text.quote, outgoingText.quote),
  link: className(text.link, outgoingText.link),
  mention: className(text.mention, outgoingText.mention),
  threadRef: className(text.threadRef, outgoingText.threadRef),
  botCommand: className(text.botCommand, outgoingText.botCommand),
  code: className(text.code, outgoingText.code),
  highlight: className(text.highlight, outgoingText.highlight),
}
