/**
 * A send's upload, drawn inside its media box (or in a document's icon
 * slot): a progress ring with "Cancel Upload" while the row is sending, and
 * "Resend" once it failed (the Mac's words, `MessageView` and
 * `DocumentView`). Absolutely positioned or of the slot's fixed size, so the
 * row never changes height when the upload starts, progresses or ends.
 *
 * The ring's progress comes from the upload's own resource
 * (`UploadSource.state`), never from the row: progress would churn rows.
 */

import type { MessageState } from "@inline/core-protocol"
import { useElement, useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import * as stylex from "@stylexjs/stylex"
import { CancelIcon, RetryIcon } from "./icons"
import type { UploadSource } from "./sources"
import { ringFraction } from "./upload"

export function UploadOverlay(props: {
  upload: UploadSource
  /** The row's state: sending shows the ring and cancel, failed shows resend. */
  state: MessageState
  /** `media`: centered over a photo or video. `file`: fills a document's 36 px icon slot. */
  variant: "media" | "file"
  /** What is uploading, for the controls' names ("photo", "file"). */
  noun: string
}) {
  const { upload } = props
  const ref = useElement(upload.part)
  const state = useSignal(upload.state)
  const failed = props.state === "failed"
  const size = props.variant === "media" ? 44 : 36
  const stroke = 2.5
  const r = (size - stroke) / 2 - 1
  const circumference = 2 * Math.PI * r
  const fraction = ringFraction(state)
  return (
    <span ref={ref} {...stylex.props(props.variant === "media" ? styles.mediaLayer : styles.fileSlot)}>
      {failed ? (
        <button
          type="button"
          aria-label={`Resend ${props.noun}`}
          title="Resend"
          onClick={(event) => {
            event.stopPropagation()
            upload.resend()
          }}
          {...stylex.props(styles.control, props.variant === "media" ? styles.mediaControl : styles.fileControl)}
        >
          <RetryIcon />
        </button>
      ) : (
        <button
          type="button"
          aria-label={`Cancel upload of ${props.noun}`}
          title="Cancel Upload"
          onClick={(event) => {
            event.stopPropagation()
            upload.cancel()
          }}
          {...stylex.props(styles.control, props.variant === "media" ? styles.mediaControl : styles.fileControl)}
        >
          <svg
            width={size}
            height={size}
            viewBox={`0 0 ${size} ${size}`}
            aria-hidden="true"
            focusable="false"
            {...stylex.props(styles.ring)}
          >
            <circle
              cx={size / 2}
              cy={size / 2}
              r={r}
              fill="none"
              strokeWidth={stroke}
              strokeLinecap="round"
              strokeDasharray={circumference}
              strokeDashoffset={circumference * (1 - fraction)}
              {...stylex.props(styles.arc)}
            />
          </svg>
          <CancelIcon size={14} />
        </button>
      )}
      {!failed && (
        <span
          role="progressbar"
          aria-label={`Uploading ${props.noun}`}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={Math.round(fraction * 100)}
          {...stylex.props(styles.hidden)}
        />
      )}
    </span>
  )
}

const styles = stylex.create({
  mediaLayer: {
    position: "absolute",
    inset: 0,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    pointerEvents: "none",
  },
  fileSlot: {
    position: "relative",
    display: "inline-flex",
    flexShrink: 0,
    inlineSize: "36px",
    blockSize: "36px",
  },
  control: {
    position: "relative",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    cursor: "pointer",
    pointerEvents: "auto",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "2px",
  },
  mediaControl: {
    inlineSize: "44px",
    blockSize: "44px",
    backgroundColor: "rgb(0 0 0 / 0.45)",
    color: color.onAccent,
  },
  fileControl: {
    inlineSize: "36px",
    blockSize: "36px",
    backgroundColor: color.accent,
    color: color.onAccent,
  },
  ring: {
    position: "absolute",
    inset: 0,
    transform: "rotate(-90deg)",
  },
  arc: {
    stroke: "currentColor",
    transitionProperty: "stroke-dashoffset",
    transitionDuration: motion.durationSlow,
    transitionTimingFunction: motion.easeOut,
  },
  hidden: {
    position: "absolute",
    inlineSize: "1px",
    blockSize: "1px",
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  },
})
