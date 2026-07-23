import {
  MessageEntity_Type,
  type MessageEntities,
  type MessageEntity,
} from "@inline-chat/protocol/core"
import * as stylex from "@stylexjs/stylex"
import type { HTMLAttributes, ReactNode } from "react"
import { colors } from "../styles/tokens.stylex"

type InlineTextEntityRange = {
  entity: MessageEntity
  start: number
  end: number
}

const isUtf16Boundary = (text: string, offset: number) => {
  if (offset <= 0 || offset >= text.length) return true
  const before = text.charCodeAt(offset - 1)
  const after = text.charCodeAt(offset)
  return !(
    before >= 0xd800 &&
    before <= 0xdbff &&
    after >= 0xdc00 &&
    after <= 0xdfff
  )
}

export const inlineTextEntityRanges = (
  text: string,
  entities: MessageEntities | undefined,
) =>
  (entities?.entities ?? []).flatMap<InlineTextEntityRange>(
    (entity) => {
      const start = Number(entity.offset)
      const length = Number(entity.length)
      const end = start + length
      if (
        !Number.isSafeInteger(start) ||
        !Number.isSafeInteger(length) ||
        start < 0 ||
        length <= 0 ||
        end > text.length ||
        !isUtf16Boundary(text, start) ||
        !isUtf16Boundary(text, end)
      ) {
        return []
      }
      return [{ entity, start, end }]
    },
  )

const safeWebUrl = (value: string) => {
  try {
    const url = new URL(value)
    return url.protocol === "https:" || url.protocol === "http:"
      ? url.href
      : undefined
  } catch {
    return undefined
  }
}

const linkForEntity = (
  text: string,
  range: InlineTextEntityRange,
) => {
  switch (range.entity.type) {
    case MessageEntity_Type.URL:
      return safeWebUrl(text.slice(range.start, range.end))
    case MessageEntity_Type.TEXT_URL:
      return range.entity.entity.oneofKind === "textUrl"
        ? safeWebUrl(range.entity.entity.textUrl.url)
        : undefined
    case MessageEntity_Type.EMAIL:
      return `mailto:${text.slice(range.start, range.end)}`
    case MessageEntity_Type.PHONE_NUMBER:
      return `tel:${text.slice(range.start, range.end)}`
    default:
      return undefined
  }
}

const wrapSegment = (
  text: string,
  ranges: readonly InlineTextEntityRange[],
  segmentStart: number,
  segmentEnd: number,
) => {
  const active = ranges.filter(
    (range) =>
      range.start <= segmentStart && range.end >= segmentEnd,
  )
  let content: ReactNode = text.slice(segmentStart, segmentEnd)
  if (
    active.some(
      ({ entity }) =>
        entity.type === MessageEntity_Type.CODE ||
        entity.type === MessageEntity_Type.PRE,
    )
  ) {
    content = <code {...stylex.props(styles.code)}>{content}</code>
  }
  if (
    active.some(
      ({ entity }) => entity.type === MessageEntity_Type.BOLD,
    )
  ) {
    content = <strong>{content}</strong>
  }
  if (
    active.some(
      ({ entity }) => entity.type === MessageEntity_Type.ITALIC,
    )
  ) {
    content = <em>{content}</em>
  }
  const mention = active.find(
    ({ entity }) =>
      entity.type === MessageEntity_Type.MENTION ||
      entity.type === MessageEntity_Type.GROUP_MENTION ||
      entity.type === MessageEntity_Type.USERNAME_MENTION,
  )
  if (mention) {
    content = (
      <span
        data-inline-mention={mention.entity.type}
        {...stylex.props(styles.mention)}
      >
        {content}
      </span>
    )
  }
  const linked = active.find((range) =>
    Boolean(linkForEntity(text, range)),
  )
  const href = linked ? linkForEntity(text, linked) : undefined
  if (href) {
    content = (
      <a
        href={href}
        target={href.startsWith("http") ? "_blank" : undefined}
        rel={href.startsWith("http") ? "noreferrer" : undefined}
        {...stylex.props(styles.link)}
      >
        {content}
      </a>
    )
  }
  return content
}

export function InlineMessageTextView({
  text,
  entities,
  ...props
}: {
  text: string
  entities?: MessageEntities
} & HTMLAttributes<HTMLSpanElement>) {
  const ranges = inlineTextEntityRanges(text, entities)
  if (ranges.length === 0) return <span {...props}>{text}</span>
  const boundaries = Array.from(
    new Set([
      0,
      text.length,
      ...ranges.flatMap((range) => [range.start, range.end]),
    ]),
  ).sort((left, right) => left - right)

  return (
    <span {...props}>
      {boundaries.slice(0, -1).map((start, index) => {
        const end = boundaries[index + 1]!
        return (
          <span key={`${start}:${end}`}>
            {wrapSegment(text, ranges, start, end)}
          </span>
        )
      })}
    </span>
  )
}

const styles = stylex.create({
  mention: {
    color: colors.accent,
    fontWeight: 600,
  },
  link: {
    color: "inherit",
    textDecorationLine: "underline",
    textDecorationThickness: "from-font",
  },
  code: {
    paddingInline: 3,
    borderRadius: 4,
    backgroundColor: "rgba(127,127,127,.14)",
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    fontSize: "0.92em",
  },
})
