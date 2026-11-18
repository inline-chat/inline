/**
 * The chat's title area: the title and one subtitle line. The subtitle is
 * `chatSubtitle` from the session (rule 15): the connection state while it is
 * worth showing (connecting, updating, waiting for network), then typing,
 * then "bot" for a direct message with a bot. Connection states live here,
 * never in a banner. Typing and other compose activity (rule 15's second
 * place) draws as `TypingLine`: the accent color with the Mac's dots.
 */

import { useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import type { ChatSubtitle } from "@inline/view/features"
import * as stylex from "@stylexjs/stylex"
import { connectionText } from "../../app/status"
import { TypingLine } from "../typing/TypingLine"
import type { OpenChat } from "./chat-pane-model"

export const subtitleText = (subtitle: ChatSubtitle): string | undefined => {
  switch (subtitle.kind) {
    case "connection":
      return connectionText[subtitle.state]
    case "typing":
      return subtitle.text
    case "bot":
      return "bot"
    case "none":
      return undefined
  }
}

/**
 * `onOpenInfo`: the title opens chat info (the Mac opens it from the title
 * in the toolbar). Without it the title is plain text.
 */
export function ChatHeader(props: { chat: OpenChat; onOpenInfo?: () => void }) {
  const header = useSignal(props.chat.header)
  const subtitle = useSignal(props.chat.subtitle)
  const text = subtitleText(subtitle)
  const typing = subtitle.kind === "typing"
  return (
    <div {...stylex.props(styles.header)}>
      {/* The lines follow the interface's direction (start-aligned); only the title's own text picks its direction. */}
      <h1 {...stylex.props(styles.title)}>
        {props.onOpenInfo ? (
          <button type="button" aria-label={`${header.title}, Chat Info`} onClick={props.onOpenInfo} {...stylex.props(styles.titleButton)}>
            <span dir="auto">
              {header.emoji ? `${header.emoji} ` : ""}
              {header.title}
            </span>
          </button>
        ) : (
          <span dir="auto">
            {header.emoji ? `${header.emoji} ` : ""}
            {header.title}
          </span>
        )}
      </h1>
      {text && (
        <p role="status" {...stylex.props(styles.subtitle, subtitle.kind === "connection" && styles.connection)}>
          {typing ? <ActivityLine chat={props.chat} /> : <span dir="auto">{text}</span>}
        </p>
      )}
    </div>
  )
}

/** The activity line reads its own signal, so a change of who is typing renders only this. */
function ActivityLine(props: { chat: OpenChat }) {
  const status = useSignal(props.chat.activity)
  return <TypingLine status={status} />
}

const styles = stylex.create({
  header: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    alignItems: "stretch",
    minInlineSize: 0,
    textAlign: "start",
  },
  title: {
    margin: 0,
    textAlign: "start",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.label,
    fontSize: font.sizeHeadline,
    fontWeight: font.weightSemibold,
    lineHeight: font.lineHeightTight,
  },
  // Reads as the title; the kit's focus ring shows only for keyboard focus.
  titleButton: {
    display: "block",
    maxInlineSize: "100%",
    margin: 0,
    padding: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: "inherit",
    fontFamily: "inherit",
    fontSize: "inherit",
    fontWeight: "inherit",
    lineHeight: "inherit",
    textAlign: "start",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    cursor: "default",
    outlineOffset: 2,
    outlineStyle: { default: "none", ":focus-visible": "solid" },
    outlineWidth: 2,
    outlineColor: color.focusRing,
    borderRadius: radius.control,
  },
  subtitle: {
    margin: 0,
    textAlign: "start",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.secondaryLabel,
    fontSize: font.sizeSubheadline,
    lineHeight: font.lineHeightTight,
  },
  connection: {
    color: color.titleTextGray,
  },
})
