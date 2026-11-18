/**
 * The message composer: renders a `ComposerModel` (see model.ts).
 *
 * The editing surface is one element handed to the composer package's DOM
 * binding through the model's `surface` part; React renders no children into
 * it. Everything that changes while typing lives in small child components
 * that read their own signals, so typing re-renders nothing here; the
 * placeholder and the send button re-render only when emptiness or
 * sendability flips. See README.md.
 */

import type { ComposerClassNames } from "@inline/composer"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { CloseIcon, IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { useId, type MouseEvent, type ReactNode } from "react"
import { AttachButton, AttachmentStrip } from "./AttachmentStrip"
import type { ComposerAttachments } from "./attachments"
import { composerSize } from "./composer.stylex"
import { PendingIcon, SendIcon } from "./icons"
import type { ComposerModel } from "./model"
import { sendShortcut } from "./text"

export type ComposerViewProps = {
  /** Created by the caller with `createComposerModel`, one per chat. */
  model: ComposerModel
  /** "Message", "Message Ada", "Reply" (in a reply thread), as the Mac app words it. Default "Message". */
  placeholder?: string
  /** The editor's accessible name. Default: the placeholder. */
  label?: string
  /** The user's spell check setting. Default true. */
  spellcheck?: boolean
  /** Show which keys send in an empty composer. Default true. */
  showSendHint?: boolean
  /**
   * The chat's attachments (`createComposerAttachments`, wired into the model
   * with `withAttachments`): the strip above the editor and the "Attach
   * files" button. Without it the composer is text only, as before.
   */
  attachments?: ComposerAttachments
  /**
   * Controls at the trailing end of the input row, before the send button
   * (the emoji button). The caller gives them a fixed size from the first
   * frame, so nothing moves when their code arrives.
   */
  trailing?: ReactNode
}

export function ComposerView(props: ComposerViewProps) {
  const model = props.model
  const placeholder = props.placeholder ?? "Message"
  const errorId = useId()
  const surface = useModel(() => model.surface({ classNames: editorClassNames, spellcheck: props.spellcheck ?? true }), [model])
  const surfaceRef = useElement(surface)

  /** A press on the pill's own padding puts the caret in the editor instead of doing nothing. */
  const focusFromChrome = (event: MouseEvent<HTMLDivElement>) => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    model.focus()
  }

  return (
    <div {...stylex.props(styles.region)}>
      <div onMouseDown={focusFromChrome} {...stylex.props(styles.pill)}>
        <Banner model={model} />
        {props.attachments && <AttachmentStrip attachments={props.attachments} />}
        <div onMouseDown={focusFromChrome} {...stylex.props(styles.row)}>
          {props.attachments && <AttachControl model={model} attachments={props.attachments} />}
          <div {...stylex.props(styles.field)}>
            <div
              ref={surfaceRef}
              aria-label={props.label ?? placeholder}
              aria-placeholder={placeholder}
              aria-describedby={errorId}
              spellCheck={props.spellcheck ?? true}
              {...stylex.props(styles.editor)}
            />
            <Placeholder model={model} text={placeholder} showHint={props.showSendHint ?? true} />
          </div>
          {props.trailing}
          <SendButton model={model} />
        </div>
      </div>
      <ErrorLine model={model} id={errorId} />
      <AutocompleteLayer model={model} />
    </div>
  )
}

/** The autocomplete popup, once its chunk (cursor and view) is here: loaded on the first trigger. */
function AutocompleteLayer(props: { model: ComposerModel }) {
  const chunk = useSignal(props.model.autocomplete.chunk)
  const cursor = useSignal(props.model.autocomplete.cursor)
  const Popup = chunk?.AutocompletePopup
  if (!Popup || !cursor) return null
  return <Popup model={props.model} cursor={cursor} />
}

/**
 * "Attach files". Enabled while editing a message, as on the Mac (its menu
 * button is enabled while `canMutateDraft`): the files wait in the strip and
 * go with the next message; Save sends only the edit.
 */
function AttachControl(props: { model: ComposerModel; attachments: ComposerAttachments }) {
  return <AttachButton attachments={props.attachments} />
}

function Placeholder(props: { model: ComposerModel; text: string; showHint: boolean }) {
  const empty = useSignal(props.model.empty)
  const hint = useSignal(props.model.sendHint)
  if (!empty) return null
  return (
    <div aria-hidden="true" {...stylex.props(styles.placeholder)}>
      <span {...stylex.props(styles.placeholderText)}>{props.text}</span>
      {props.showHint && <span {...stylex.props(styles.hint)}>{hint}</span>}
    </div>
  )
}

function SendButton(props: { model: ComposerModel }) {
  const { model } = props
  const canSend = useSignal(model.composer.canSend)
  const sending = useSignal(model.composer.sending)
  const editing = useSignal(model.composer.editing) !== null
  const sendKey = useSignal(model.sendKey)
  return (
    <IconButton
      label={editing ? "Save" : "Send"}
      icon={sending ? <PendingIcon /> : <SendIcon />}
      // aria-disabled, not disabled: a disabled button drops keyboard focus mid-send.
      aria-disabled={!canSend}
      aria-busy={sending || undefined}
      aria-keyshortcuts={sendShortcut(sendKey, model.platform)}
      // Keep focus (and the caret) in the editor when the button is pressed with a pointer.
      onMouseDown={(event) => event.preventDefault()}
      onClick={() => {
        if (canSend) model.send()
      }}
      style={[styles.send, canSend || sending ? styles.sendReady : styles.sendIdle]}
    />
  )
}

function Banner(props: { model: ComposerModel }) {
  const banner = useSignal(props.model.banner)
  if (!banner) return null
  const sender = banner.preview?.senderName
  return (
    <div {...stylex.props(styles.banner)}>
      <span aria-hidden="true" {...stylex.props(styles.bannerBar)} />
      <div {...stylex.props(styles.bannerText)}>
        <div {...stylex.props(styles.bannerTitle)}>
          {banner.kind === "edit" ? (
            "Edit Message"
          ) : sender ? (
            <>
              Reply to <bdi>{sender}</bdi>
            </>
          ) : (
            "Reply"
          )}
        </div>
        {banner.preview?.text ? (
          <div dir="auto" {...stylex.props(styles.bannerPreview)}>
            {banner.preview.text}
          </div>
        ) : null}
      </div>
      <IconButton
        size="small"
        label={banner.kind === "edit" ? "Cancel edit" : "Cancel reply"}
        icon={<CloseIcon size={12} />}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => {
          props.model.dismissBanner()
          props.model.focus()
        }}
      />
    </div>
  )
}

/** Always rendered so screen readers announce a new error; empty and zero-height without one. */
function ErrorLine(props: { model: ComposerModel; id: string }) {
  const text = useSignal(props.model.errorText)
  return (
    <div id={props.id} role="alert" {...stylex.props(styles.error)}>
      {text}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Styles

const marks = stylex.create({
  line: {},
  bold: { fontWeight: font.weightBold },
  italic: { fontStyle: "italic" },
  underline: { textDecorationLine: "underline" },
  strikethrough: { textDecorationLine: "line-through" },
  code: {
    fontFamily: font.familyMono,
    fontSize: "0.92em",
    backgroundColor: color.controlTrack,
    borderRadius: radius.small,
  },
  pre: { fontFamily: font.familyMono, fontSize: "0.92em" },
  link: { color: color.link },
  highlight: { backgroundColor: `color-mix(in srgb, ${color.yellow} 35%, transparent)` },
  blockquote: { color: color.secondaryLabel },
  atom: { color: color.accent, fontWeight: font.weightMedium, cursor: "default" },
})

/** Class names the composer binding puts on lines, marked runs and atoms. */
const editorClassNames: ComposerClassNames = {
  line: stylex.props(marks.line).className,
  bold: stylex.props(marks.bold).className,
  italic: stylex.props(marks.italic).className,
  underline: stylex.props(marks.underline).className,
  strikethrough: stylex.props(marks.strikethrough).className,
  code: stylex.props(marks.code).className,
  pre: stylex.props(marks.pre).className,
  textUrl: stylex.props(marks.link).className,
  link: stylex.props(marks.link).className,
  highlight: stylex.props(marks.highlight).className,
  blockquote: stylex.props(marks.blockquote).className,
  atom: stylex.props(marks.atom).className,
}

const styles = stylex.create({
  region: {
    display: "flex",
    flexDirection: "column",
    gap: space.xs,
    minInlineSize: 0,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    color: color.label,
  },
  pill: {
    display: "flex",
    flexDirection: "column",
    minInlineSize: 0,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: {
      default: color.composeOutline,
      ":focus-within": `color-mix(in srgb, ${color.accent} 35%, ${color.composeOutline})`,
    },
    borderRadius: composerSize.pillRadius,
    transitionProperty: "border-color",
    transitionDuration: motion.durationFast,
    cursor: "text",
  },
  row: {
    display: "flex",
    alignItems: "flex-end",
    minInlineSize: 0,
  },
  field: {
    position: "relative",
    flexGrow: 1,
    minInlineSize: 0,
  },
  editor: {
    boxSizing: "border-box",
    minBlockSize: composerSize.minHeight,
    maxBlockSize: composerSize.maxHeight,
    overflowY: "auto",
    overscrollBehavior: "contain",
    paddingBlock: composerSize.textPaddingBlock,
    paddingInlineStart: composerSize.textPaddingInline,
    paddingInlineEnd: space.sm,
    lineHeight: composerSize.lineHeight,
    whiteSpace: "pre-wrap",
    overflowWrap: "anywhere",
    textAlign: "start",
    caretColor: color.accent,
    // The Mac composer has no focus ring; the pill's border tints instead.
    outline: "none",
    cursor: "text",
  },
  placeholder: {
    position: "absolute",
    insetBlockStart: 0,
    insetInline: 0,
    display: "flex",
    alignItems: "baseline",
    gap: space.md,
    paddingBlock: composerSize.textPaddingBlock,
    paddingInlineStart: composerSize.textPaddingInline,
    paddingInlineEnd: space.sm,
    lineHeight: composerSize.lineHeight,
    color: color.placeholderText,
    pointerEvents: "none",
    userSelect: "none",
    whiteSpace: "nowrap",
    overflow: "hidden",
  },
  placeholderText: { flexShrink: 0 },
  hint: {
    marginInlineStart: "auto",
    minInlineSize: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    fontSize: font.sizeCallout,
    color: color.tertiaryLabel,
  },
  send: {
    flexShrink: 0,
    inlineSize: composerSize.sendButton,
    blockSize: composerSize.sendButton,
    margin: composerSize.sendInset,
    borderRadius: radius.pill,
    transitionProperty: "background-color, color",
    transitionDuration: motion.durationFast,
  },
  sendReady: {
    backgroundColor: { default: color.accent, ":hover": color.accentHover, ":active": color.accentPressed },
    color: color.onAccent,
  },
  sendIdle: {
    backgroundColor: { default: color.controlTrack, ":hover": color.controlTrack, ":active": color.controlTrack },
    color: color.tertiaryLabel,
    cursor: "default",
  },
  banner: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    paddingBlockStart: space.sm,
    paddingInlineStart: composerSize.textPaddingInline,
    paddingInlineEnd: space.sm,
    minInlineSize: 0,
    cursor: "default",
  },
  bannerBar: {
    alignSelf: "stretch",
    flexShrink: 0,
    inlineSize: "2px",
    borderRadius: radius.pill,
    backgroundColor: color.accent,
  },
  bannerText: {
    display: "flex",
    flexDirection: "column",
    flexGrow: 1,
    minInlineSize: 0,
    lineHeight: font.lineHeightTight,
  },
  bannerTitle: {
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
    color: color.accent,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  bannerPreview: {
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
    textAlign: "start",
  },
  error: {
    paddingInline: composerSize.textPaddingInline,
    fontSize: font.sizeCallout,
    lineHeight: font.lineHeightTight,
    color: color.red,
    display: { default: "block", ":empty": "none" },
  },
})
