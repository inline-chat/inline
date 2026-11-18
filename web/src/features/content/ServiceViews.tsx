/**
 * Service rows and the small lines around a message: the forward header,
 * "Sent via" and the reply thread summary. Wording and targets come from
 * `@inline/chat-ui` (`service/`); names from `ContentEnv.names`.
 */

import * as stylex from "@stylexjs/stylex"
import { type ForwardHeaderModel, type RepliesSummaryModel, serviceRowModel, type ViaModel } from "@inline/chat-ui"
import type { MessageRow } from "@inline/core-protocol"
import { Avatar } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo } from "react"
import type { ContentEnv } from "./env"
import { ChevronIcon } from "./icons"
import type { RowContent } from "./row-content"

// ---------------------------------------------------------------------------
// Service row

export type ServiceRowProps = {
  readonly message: MessageRow
  readonly env: ContentEnv
  /** Written as `data-timeline-key`. */
  readonly itemKey?: string
}

/**
 * A service message as its own timeline row: a centered pill (grid
 * transcripts: a full-width, start-aligned one), never grouped, no avatar.
 * Renders nothing when `serviceRowModel` says the row is an ordinary message
 * (a transcript turn by its sender): render a message row then.
 */
export const ServiceRow = memo(function ServiceRow(props: ServiceRowProps) {
  const { message, env } = props
  const sender = env.names.user?.(message.fromId)?.name
  const model = serviceRowModel(message, sender ? { sender } : {})
  if (!model) return null
  const onLink = env.handlers.onServiceLink
  return (
    <div
      data-message-row={message.id}
      data-service-row=""
      data-timeline-key={props.itemKey}
      {...stylex.props(styles.serviceRow, model.align === "start" && styles.serviceRowStart)}
    >
      <p dir="auto" {...stylex.props(styles.pill, model.align === "start" && styles.pillStart)}>
        {model.segments.map((segment, index) => {
          const link = segment.link
          const tone = toneStyles[segment.tone]
          return link && onLink ? (
            <button
              // Segments are positional and never reorder.
              key={index}
              type="button"
              onClick={() => onLink(link)}
              {...stylex.props(styles.segmentLink, tone)}
            >
              {segment.text}
            </button>
          ) : (
            <span key={index} {...stylex.props(tone)}>
              {segment.text}
            </span>
          )
        })}
      </p>
    </div>
  )
})

// ---------------------------------------------------------------------------
// Forward header, "Sent via"

export const ForwardLine = memo(function ForwardLine(props: { model: ForwardHeaderModel; ctx: RowContent }) {
  const { model, ctx } = props
  const onForward = ctx.env.handlers.onForward
  const target = model.target
  const tone = ctx.tone === "outgoing" ? styles.lineOutgoing : styles.lineIncoming
  if (target && onForward) {
    return (
      <button type="button" onClick={() => onForward(target)} {...stylex.props(styles.line, styles.lineButton, tone)}>
        {model.text}
      </button>
    )
  }
  return <span {...stylex.props(styles.line, tone)}>{model.text}</span>
})

export const ViaLine = memo(function ViaLine(props: { model: ViaModel; ctx: RowContent }) {
  const { model, ctx } = props
  return (
    <span title={model.tooltip} {...stylex.props(styles.via, ctx.tone === "outgoing" ? styles.lineOutgoing : styles.subtle)}>
      {model.label}
    </span>
  )
})

// ---------------------------------------------------------------------------
// Reply thread summary (Mac `ReplyThreadSummaryView`)

export const RepliesSummary = memo(function RepliesSummary(props: { model: RepliesSummaryModel; ctx: RowContent }) {
  const { model, ctx } = props
  const onOpen = ctx.env.handlers.onOpenReplies
  const people = model.avatars.map((userId) => ({ userId, person: ctx.env.names.user?.(userId) }))
  const label = model.title ? `${model.title}, ${model.label}` : model.label
  return (
    <button
      type="button"
      aria-label={model.hasUnread ? `${label}, unread` : label}
      disabled={!onOpen}
      onClick={onOpen ? () => onOpen({ rowId: ctx.rowId, chatId: model.chatId }) : undefined}
      {...stylex.props(styles.summary, model.title ? styles.summaryTitled : styles.summaryPlain)}
    >
      {model.title && (
        <span dir="auto" {...stylex.props(styles.summaryTitle)}>
          {model.title}
        </span>
      )}
      <span {...stylex.props(styles.summaryLine)}>
        {people.length > 0 && (
          <span aria-hidden="true" {...stylex.props(styles.avatars)}>
            {people.map(({ userId, person }) => (
              <span key={userId} {...stylex.props(styles.avatar)}>
                <Avatar
                  name={person?.name ?? "User"}
                  seed={person?.seed ?? userId}
                  {...(person?.photoUrl ? { src: person.photoUrl } : {})}
                  size="small"
                />
              </span>
            ))}
          </span>
        )}
        <span {...stylex.props(styles.count, model.title !== undefined && styles.countSmall)}>{model.label}</span>
        {model.hasUnread && <span aria-hidden="true" {...stylex.props(styles.unread)} />}
        <span aria-hidden="true" {...stylex.props(styles.chevron)}>
          <ChevronIcon />
        </span>
      </span>
    </button>
  )
})

const styles = stylex.create({
  serviceRow: {
    display: "flex",
    justifyContent: "center",
    paddingInline: "16px",
    paddingBlock: "4px",
    boxSizing: "border-box",
    minBlockSize: "34px",
    alignItems: "center",
  },
  serviceRowStart: { justifyContent: "stretch" },
  pill: {
    margin: 0,
    maxInlineSize: "90%",
    paddingInline: "10px",
    paddingBlock: "5px",
    boxSizing: "border-box",
    borderRadius: "11px",
    backgroundColor: `color-mix(in srgb, ${color.label} 6%, transparent)`,
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
    lineHeight: "16px",
    textAlign: "center",
    overflowWrap: "anywhere",
    whiteSpace: "pre-wrap",
  },
  pillStart: { inlineSize: "100%", maxInlineSize: "100%", textAlign: "start" },
  segmentLink: {
    display: "inline",
    padding: 0,
    borderStyle: "none",
    backgroundColor: "transparent",
    fontFamily: "inherit",
    fontSize: "inherit",
    lineHeight: "inherit",
    cursor: "pointer",
    textDecoration: { default: "none", ":hover": "underline" },
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  line: {
    display: "block",
    maxInlineSize: "100%",
    padding: 0,
    borderStyle: "none",
    backgroundColor: "transparent",
    fontFamily: "inherit",
    fontSize: font.sizeCallout,
    fontWeight: font.weightMedium,
    lineHeight: "16px",
    textAlign: "start",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  lineButton: {
    cursor: "pointer",
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  lineIncoming: { color: color.accent },
  lineOutgoing: { color: `color-mix(in srgb, ${color.onAccent} 85%, transparent)` },
  via: {
    display: "block",
    fontSize: font.sizeFootnote,
    lineHeight: "14px",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    cursor: "default",
  },
  subtle: { color: color.secondaryLabel },
  summary: {
    display: "inline-flex",
    flexDirection: "column",
    justifyContent: "center",
    minInlineSize: "200px",
    maxInlineSize: "100%",
    paddingInline: space.md,
    boxSizing: "border-box",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: "8px",
    backgroundColor: { default: color.windowBackground, ":hover": color.controlHover },
    color: color.label,
    fontFamily: "inherit",
    textAlign: "start",
    cursor: { default: "pointer", ":disabled": "default" },
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  summaryPlain: { blockSize: "30px" },
  summaryTitled: { blockSize: "46px", gap: "1px" },
  summaryTitle: {
    fontSize: font.sizeBody,
    fontWeight: font.weightSemibold,
    lineHeight: "16px",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  summaryLine: { display: "flex", alignItems: "center", gap: "6px", minInlineSize: 0 },
  avatars: { display: "inline-flex", flexShrink: 0 },
  avatar: {
    display: "inline-flex",
    marginInlineStart: { default: "-6px", ":first-child": 0 },
    borderRadius: radius.pill,
    boxShadow: `0 0 0 1.5px ${color.windowBackground}`,
  },
  count: { fontSize: font.sizeBody, fontWeight: font.weightMedium, color: color.accent, whiteSpace: "nowrap" },
  countSmall: { fontSize: font.sizeSubheadline },
  unread: { flexShrink: 0, inlineSize: "6px", blockSize: "6px", borderRadius: radius.pill, backgroundColor: color.accent },
  chevron: {
    display: "inline-flex",
    marginInlineStart: "auto",
    color: color.tertiaryLabel,
    transform: { default: null, ":dir(rtl)": "scaleX(-1)" },
  },
})

const toneStyles = stylex.create({
  primary: { color: color.label },
  secondary: { color: color.secondaryLabel },
  tertiary: { color: color.tertiaryLabel },
})
