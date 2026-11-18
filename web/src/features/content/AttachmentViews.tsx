/**
 * Attachments under a message (Mac `Attachments/`): link preview cards,
 * compact or with large media whose box is reserved from the model, and
 * external task cards. A card opens only a safe web link (an anchor with
 * `rel="noopener noreferrer"`); a refused URL leaves the text, unclickable.
 * Embeds are never framed.
 */

import * as stylex from "@stylexjs/stylex"
import {
  type AttachmentModel,
  externalTaskHeadline,
  type ExternalTaskModel,
  largePreviewMediaHeight,
  type UrlPreviewModel,
  type WebLink,
} from "@inline/chat-ui"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, type ReactNode } from "react"
import { PhotoBox, PlayBadge } from "./MediaViews"
import { contentText } from "./RichText"
import type { RowContent } from "./row-content"

export const Attachments = memo(function Attachments(props: { models: readonly AttachmentModel[]; ctx: RowContent }) {
  if (props.models.length === 0) return null
  return (
    <div {...stylex.props(styles.list)}>
      {props.models.map((model) =>
        model.kind === "urlPreview" ? (
          <UrlPreviewCard key={model.key} model={model} ctx={props.ctx} />
        ) : (
          <ExternalTaskCard key={model.key} model={model} ctx={props.ctx} />
        ),
      )}
    </div>
  )
})

/** An anchor for a safe web link, or a plain container when there is none. */
function CardLink(props: { link: WebLink | undefined; ctx: RowContent; label?: string; children: ReactNode; style: stylex.StyleXStyles }) {
  const { link } = props
  if (!link) return <div {...stylex.props(props.style)}>{props.children}</div>
  const onExternalLink = props.ctx.env.handlers.onExternalLink
  return (
    <a
      href={link.href}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={props.label}
      onClick={onExternalLink ? (event) => onExternalLink(link, event) : undefined}
      {...stylex.props(props.style, styles.link)}
    >
      {props.children}
    </a>
  )
}

export const UrlPreviewCard = memo(function UrlPreviewCard(props: { model: UrlPreviewModel; ctx: RowContent }) {
  const { model, ctx } = props
  const outgoing = ctx.tone === "outgoing"
  const available = ctx.env.layout.availableWidth
  const width = Math.min(model.maxWidth, available !== undefined && available > 0 ? available : model.maxWidth)
  const media = model.media
  if (model.layout === "large" && media) {
    const box = { width, height: largePreviewMediaHeight(media, width) }
    return (
      <CardLink
        link={model.link}
        ctx={ctx}
        style={[styles.large, dynamic.width(width), outgoing && styles.cardOutgoing]}
      >
        <PhotoBox ctx={ctx} mediaKey={`${model.key}:media`} photo={media.photo} preview={media.preview} box={box} sizing="aspect" radius="small">
          {media.kind === "video" && <PlayBadge />}
          {media.durationText && <span {...stylex.props(styles.duration)}>{media.durationText}</span>}
        </PhotoBox>
        {model.author && <span {...stylex.props(styles.author)}>{model.author.name}</span>}
        {model.title && (
          <span dir="auto" {...stylex.props(styles.title, styles.twoLines)}>
            {model.title}
          </span>
        )}
        {model.subtitle && (
          <span dir="auto" {...stylex.props(styles.subtitle, contentText.ellipsis, outgoing ? styles.subtleOutgoing : styles.subtle)}>
            {model.subtitle}
          </span>
        )}
        {model.description && (
          <span dir="auto" {...stylex.props(styles.description, model.style === "x" ? null : styles.threeLines)}>
            {model.description}
          </span>
        )}
      </CardLink>
    )
  }
  return (
    <CardLink link={model.link} ctx={ctx} style={[styles.compact, dynamic.maxWidth(width), outgoing && styles.cardOutgoing]}>
      <span aria-hidden="true" {...stylex.props(styles.accent, outgoing && styles.accentOutgoing)} />
      {media ? (
        <PhotoBox
          ctx={ctx}
          mediaKey={`${model.key}:thumbnail`}
          photo={media.photo}
          preview={media.preview}
          box={thumbnailBox}
          sizing="fixed"
          radius="small"
        />
      ) : (
        model.iconEmoji && (
          <span aria-hidden="true" {...stylex.props(styles.emoji)}>
            {model.iconEmoji}
          </span>
        )
      )}
      <span {...stylex.props(styles.compactText)}>
        <span dir="auto" {...stylex.props(styles.title, contentText.ellipsis)}>
          {model.style === "x" ? (model.author?.name ?? model.source) : model.title}
        </span>
        {(model.style === "x" ? model.description : model.subtitle) && (
          <span dir="auto" {...stylex.props(styles.subtitle, contentText.ellipsis, outgoing ? styles.subtleOutgoing : styles.subtle)}>
            {model.style === "x" ? model.description : model.subtitle}
          </span>
        )}
      </span>
    </CardLink>
  )
})

const thumbnailBox = { width: 32, height: 32 }

export const ExternalTaskCard = memo(function ExternalTaskCard(props: { model: ExternalTaskModel; ctx: RowContent }) {
  const { model, ctx } = props
  const name = model.userId ? (ctx.env.names.user?.(model.userId)?.name ?? "Someone") : ""
  const outgoing = ctx.tone === "outgoing"
  return (
    <CardLink link={model.link} ctx={ctx} style={[styles.task, dynamic.height(model.height), outgoing && styles.cardOutgoing]}>
      <span {...stylex.props(styles.subtitle, contentText.ellipsis, outgoing ? styles.subtleOutgoing : styles.subtle)}>
        {externalTaskHeadline(model, name)}
        {model.number ? ` · ${model.number}` : ""}
      </span>
      <span {...stylex.props(styles.taskLine)}>
        <span aria-hidden="true" {...stylex.props(styles.checkbox, model.status === "done" && styles.checkboxDone)} />
        <span dir="auto" {...stylex.props(styles.title, contentText.ellipsis)}>
          {model.title}
        </span>
      </span>
    </CardLink>
  )
})

const styles = stylex.create({
  list: { display: "flex", flexDirection: "column", gap: space.sm, minInlineSize: 0 },
  link: {
    textDecoration: "none",
    color: "inherit",
    cursor: "pointer",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
  compact: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    blockSize: "40px",
    maxInlineSize: "100%",
    boxSizing: "border-box",
    paddingInlineEnd: space.md,
    borderRadius: radius.control,
    overflow: "hidden",
    backgroundColor: `color-mix(in srgb, ${color.accent} 8%, transparent)`,
  },
  cardOutgoing: { backgroundColor: `color-mix(in srgb, ${color.onAccent} 14%, transparent)` },
  accent: { alignSelf: "stretch", flexShrink: 0, inlineSize: "3px", backgroundColor: color.accent },
  accentOutgoing: { backgroundColor: color.onAccent },
  emoji: { flexShrink: 0, fontSize: "20px", lineHeight: 1 },
  compactText: { display: "flex", flexDirection: "column", minInlineSize: 0, flexGrow: 1 },
  title: { fontSize: font.sizeBody, fontWeight: font.weightSemibold, lineHeight: "16px" },
  subtitle: { fontSize: font.sizeCallout, lineHeight: "15px" },
  subtle: { color: color.secondaryLabel },
  subtleOutgoing: { color: `color-mix(in srgb, ${color.onAccent} 75%, transparent)` },
  large: {
    display: "flex",
    flexDirection: "column",
    gap: space.xxs,
    maxInlineSize: "100%",
    boxSizing: "border-box",
    paddingBlockEnd: space.sm,
    paddingInlineStart: space.md,
    borderInlineStartWidth: "3px",
    borderInlineStartStyle: "solid",
    borderInlineStartColor: color.accent,
    borderRadius: radius.control,
  },
  author: { fontSize: font.sizeCallout, fontWeight: font.weightMedium, marginBlockStart: space.xs },
  twoLines: { display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" },
  threeLines: { display: "-webkit-box", WebkitLineClamp: 3, WebkitBoxOrient: "vertical", overflow: "hidden" },
  description: { fontSize: font.sizeCallout, lineHeight: "16px", whiteSpace: "pre-wrap", overflowWrap: "anywhere" },
  duration: {
    position: "absolute",
    insetBlockEnd: space.xs,
    insetInlineEnd: space.xs,
    paddingInline: space.xs,
    borderRadius: radius.small,
    backgroundColor: "rgb(0 0 0 / 0.55)",
    color: color.onAccent,
    fontSize: font.sizeFootnote,
    fontVariantNumeric: "tabular-nums",
  },
  task: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    gap: "2px",
    maxInlineSize: "100%",
    minInlineSize: "200px",
    boxSizing: "border-box",
    paddingInline: space.md,
    borderRadius: radius.control,
    backgroundColor: `color-mix(in srgb, ${color.label} 5%, transparent)`,
  },
  taskLine: { display: "flex", alignItems: "center", gap: space.sm, minInlineSize: 0 },
  checkbox: {
    flexShrink: 0,
    inlineSize: "12px",
    blockSize: "12px",
    boxSizing: "border-box",
    borderWidth: "1.5px",
    borderStyle: "solid",
    borderColor: color.secondaryLabel,
    borderRadius: "3px",
  },
  checkboxDone: { backgroundColor: color.green, borderColor: color.green },
})

const dynamic = stylex.create({
  width: (width: number) => ({ inlineSize: `${width}px` }),
  maxWidth: (width: number) => ({ maxInlineSize: `min(100%, ${width}px)` }),
  height: (height: number) => ({ blockSize: `${height}px` }),
})
