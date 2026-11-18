/**
 * Text inside content (block paragraphs, headings, card titles, form labels):
 * the existing `MessageText` view over a `RichText` range, with class names
 * for the bubble tone. Links, mentions and styles work as in message text.
 */

import * as stylex from "@stylexjs/stylex"
import type { RichText } from "@inline/chat-ui"
import { type MessageTextClassNames, MessageText } from "@inline/chat-ui/react"
import { chatText } from "@inline/ui/tokens/chat-text.stylex"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { themeColor } from "@inline/ui/tokens/theme-color.stylex"
import type { RowContent } from "./row-content"

export function RichTextView(props: { text: RichText; ctx: RowContent }) {
  const handlers = props.ctx.env.handlers
  return (
    <MessageText
      document={props.text.document}
      classNames={props.ctx.tone === "outgoing" ? outgoingClasses : incomingClasses}
      onMention={handlers.onMention}
      onThreadRef={handlers.onThreadRef}
      onBotCommand={handlers.onBotCommand}
      onAppLink={handlers.onAppLink}
      onExternalLink={handlers.onExternalLink}
    />
  )
}

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
    backgroundColor: `color-mix(in srgb, ${color.label} 6%, transparent)`,
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
    color: themeColor.secondaryBubbleLink,
    textDecoration: { default: "none", ":hover": "underline" },
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  mention: {
    color: themeColor.secondaryBubbleLink,
    fontWeight: font.weightMedium,
    cursor: "pointer",
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  threadRef: {
    color: themeColor.secondaryBubbleLink,
    cursor: "pointer",
    borderRadius: "2px",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  botCommand: {
    color: themeColor.secondaryBubbleLink,
    cursor: "pointer",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  math: { fontFamily: font.familyMono, fontSize: "0.92em" },
  code: {
    paddingInline: "3px",
    borderRadius: radius.small,
    backgroundColor: `color-mix(in srgb, ${color.label} 7%, transparent)`,
    fontFamily: font.familyMono,
    fontSize: "0.92em",
  },
  highlight: {
    color: "inherit",
    borderRadius: "2px",
    backgroundColor: `color-mix(in srgb, ${color.yellow} 45%, transparent)`,
  },
})

const outgoing = stylex.create({
  codeBlock: { backgroundColor: `color-mix(in srgb, ${color.onAccent} 15%, transparent)` },
  quote: { borderInlineStartColor: `color-mix(in srgb, ${color.onAccent} 70%, transparent)` },
  link: { color: "inherit", textDecoration: "underline" },
  mention: { color: "inherit", fontWeight: font.weightSemibold },
  threadRef: { color: "inherit", textDecoration: "underline" },
  botCommand: { color: "inherit", textDecoration: "underline" },
  code: { backgroundColor: `color-mix(in srgb, ${color.onAccent} 18%, transparent)` },
  highlight: { backgroundColor: `color-mix(in srgb, ${color.onAccent} 30%, transparent)` },
})

const className = (...parts: stylex.StyleXStyles[]): string | undefined => stylex.props(...parts).className

const incomingClasses: MessageTextClassNames = {
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
}

const outgoingClasses: MessageTextClassNames = {
  ...incomingClasses,
  codeBlock: className(text.codeBlock, outgoing.codeBlock),
  quote: className(text.quote, outgoing.quote),
  link: className(text.link, outgoing.link),
  mention: className(text.mention, outgoing.mention),
  threadRef: className(text.threadRef, outgoing.threadRef),
  botCommand: className(text.botCommand, outgoing.botCommand),
  code: className(text.code, outgoing.code),
  highlight: className(text.highlight, outgoing.highlight),
}

/** Text styles shared by content views. */
export const contentText = stylex.create({
  body: {
    fontFamily: chatText.messageFontFamily,
    fontSize: chatText.messageFontSize,
    lineHeight: chatText.messageLineHeight,
  },
  secondary: { color: color.secondaryLabel },
  secondaryOutgoing: { color: `color-mix(in srgb, ${color.onAccent} 75%, transparent)` },
  caption: { fontSize: font.sizeCallout, lineHeight: font.lineHeightTight },
  mono: { fontFamily: font.familyMono, fontSize: font.sizeCallout },
  ellipsis: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", minInlineSize: 0 },
})
