/**
 * The media viewer: a modal `<dialog>` in the top layer over the window,
 * showing one photo at fit size (or a video with the browser's controls),
 * with Previous and Next for the media of the loaded window, the position,
 * and Close. Left and Right step (mirrored in right to left), Escape and a
 * press on the backdrop close, focus returns to what opened it (the kit's
 * `DialogController`). No zoom yet. Part of the viewer's chunk.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { ChevronIcon, CloseIcon, IconButton, Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { KeyboardEvent } from "react"
import type { MediaSource } from "../content/sources"
import type { MediaViewerModel } from "./media-viewer"

const directionOf = (element: Element): "ltr" | "rtl" =>
  element.closest("[dir]")?.getAttribute("dir") === "rtl" ||
  element.ownerDocument.documentElement.getAttribute("dir") === "rtl"
    ? "rtl"
    : "ltr"

export function MediaViewer(props: { model: MediaViewerModel }) {
  const { model } = props
  const dialog = model.dialog
  const contentRef = useElement(dialog.content ?? null)
  const surfaceRef = useElement(dialog.surface ?? null)
  const onKeyDown = (event: KeyboardEvent<HTMLDialogElement>) => {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
    if (model.key(event.key, directionOf(event.currentTarget))) event.preventDefault()
  }
  return (
    <dialog ref={contentRef} onKeyDown={onKeyDown} {...stylex.props(styles.dialog)}>
      <div ref={surfaceRef} {...stylex.props(styles.frame)}>
        <div {...stylex.props(styles.bar)}>
          <Position model={model} />
          <IconButton label="Close" icon={<CloseIcon />} onClick={() => model.close()} style={styles.button} />
        </div>
        <div {...stylex.props(styles.stage)}>
          <StepButton model={model} step="previous" />
          <Current model={model} />
          <StepButton model={model} step="next" />
        </div>
      </div>
    </dialog>
  )
}

function Position(props: { model: MediaViewerModel }) {
  const position = useSignal(props.model.position)
  return (
    <p aria-live="polite" {...stylex.props(styles.position)}>
      {position ?? ""}
    </p>
  )
}

function StepButton(props: { model: MediaViewerModel; step: "previous" | "next" }) {
  const enabled = useSignal(props.step === "next" ? props.model.canNext : props.model.canPrevious)
  if (props.model.items.length < 2) return <span {...stylex.props(styles.stepSpace)} />
  return (
    <IconButton
      label={props.step === "next" ? "Next" : "Previous"}
      icon={<ChevronIcon style={props.step === "previous" ? styles.back : undefined} />}
      disabled={!enabled}
      onClick={() => (props.step === "next" ? props.model.next() : props.model.previous())}
      style={styles.button}
    />
  )
}

function Current(props: { model: MediaViewerModel }) {
  const item = useSignal(props.model.current)
  const source = useSignal(props.model.source)
  if (!item || !source) return <div {...stylex.props(styles.media)} />
  return <MediaView key={item.key} source={source} kind={item.kind} label={item.kind === "video" ? "Video" : "Photo"} />
}

function MediaView(props: { source: MediaSource; kind: "photo" | "video"; label: string }) {
  const state = useSignal(props.source.state)
  return (
    <div {...stylex.props(styles.media)}>
      {state.status === "ready" ? (
        props.kind === "video" ? (
          <video src={state.url} controls autoPlay playsInline aria-label={props.label} {...stylex.props(styles.fit)} />
        ) : (
          <img src={state.url} alt={props.label} decoding="async" {...stylex.props(styles.fit)} />
        )
      ) : state.status === "pending" ? (
        <Progress
          variant="spinner"
          label={`Loading ${props.label.toLowerCase()}`}
          {...(state.progress !== undefined ? { value: state.progress } : {})}
        />
      ) : (
        <div {...stylex.props(styles.failed)}>
          <p {...stylex.props(styles.failedText)}>{`This ${props.label.toLowerCase()} couldn't be loaded.`}</p>
          <button type="button" onClick={() => props.source.retry()} {...stylex.props(styles.retry)}>
            Try Again
          </button>
        </div>
      )}
    </div>
  )
}

const styles = stylex.create({
  dialog: {
    inlineSize: "100vw",
    blockSize: "100dvh",
    maxInlineSize: "100vw",
    maxBlockSize: "100dvh",
    margin: 0,
    padding: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    // Dark in both appearances (the Mac's Quick Look): the kit's tokens resolve to their dark values here.
    colorScheme: "dark",
    color: color.label,
    // The one raw value: a viewer's backdrop is darker than any dialog's (`color.backdrop`).
    "::backdrop": {
      backgroundColor: "rgb(0 0 0 / 0.88)",
    },
  },
  frame: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    fontFamily: font.familySystem,
  },
  bar: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: space.md,
    flexShrink: 0,
    paddingBlock: space.sm,
    paddingInline: space.md,
  },
  position: {
    margin: 0,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
  },
  stage: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    flexGrow: 1,
    minBlockSize: 0,
    paddingInline: space.sm,
    paddingBlockEnd: space.lg,
  },
  stepSpace: {
    inlineSize: 28,
    flexShrink: 0,
  },
  button: {
    color: color.label,
    flexShrink: 0,
  },
  back: {
    transform: "scaleX(-1)",
  },
  media: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexGrow: 1,
    minInlineSize: 0,
    blockSize: "100%",
  },
  fit: {
    display: "block",
    maxInlineSize: "100%",
    maxBlockSize: "100%",
    objectFit: "contain",
  },
  failed: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: space.sm,
  },
  failedText: {
    margin: 0,
    fontSize: font.sizeBody,
  },
  retry: {
    paddingBlock: space.xs,
    paddingInline: space.md,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    backgroundColor: color.control,
    color: color.controlText,
    fontSize: font.sizeBody,
    cursor: "pointer",
  },
})
