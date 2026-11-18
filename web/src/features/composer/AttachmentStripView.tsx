/**
 * The attachment strip above the editor: thumbnails for images, rows for
 * files, progress, retry and remove, and a line saying what was refused.
 * Its own chunk (`strip-chunk.ts`), loaded when the first file is added;
 * `AttachmentStrip` (in `AttachmentStrip.tsx`, first frame) renders it once
 * it is here. Renders `ComposerAttachments` (framework-free); nothing here
 * holds state that matters.
 *
 * Mac reference: `apple/InlineMac/Views/Compose/ComposeAttachments.swift`
 * (images as thumbnails, files as rows, a remove control on each).
 */

import { useSignal } from "@inline/reactive/react"
import { CloseIcon, IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import { displayFileName } from "../content/file-name"
import type { AttachmentStatus, ComposerAttachments, PendingAttachment } from "./attachments"
import { FileIcon, RetryIcon } from "./icons"

const CHIP = 64

/** Pending attachments, then a line saying what was refused. Renders nothing when both are empty. */
export function AttachmentStripView(props: { attachments: ComposerAttachments }) {
  const items = useSignal(props.attachments.items)
  const notice = useSignal(props.attachments.notice)
  if (items.length === 0 && notice === null) return null
  return (
    <div {...stylex.props(styles.region)} onMouseDown={(event) => event.stopPropagation()}>
      {items.length > 0 && (
        <ul aria-label="Attachments" {...stylex.props(styles.strip)}>
          {items.map((item) => (
            <AttachmentChip key={item.id} item={item} attachments={props.attachments} />
          ))}
        </ul>
      )}
      {notice !== null && (
        <div role="alert" {...stylex.props(styles.notice)}>
          <span {...stylex.props(styles.noticeText)}>{notice}</span>
          <IconButton
            size="small"
            label="Dismiss"
            icon={<CloseIcon size={10} />}
            onClick={() => props.attachments.dismissNotice()}
          />
        </div>
      )}
    </div>
  )
}

const statusText = (status: AttachmentStatus): string => {
  switch (status.phase) {
    case "staging":
      return "Preparing…"
    case "uploading":
      return `Uploading ${Math.round(status.fraction * 100)}%`
    case "uploaded":
      return ""
    case "failed":
      return status.message
  }
}

const AttachmentChip = memo(function AttachmentChip(props: { item: PendingAttachment; attachments: ComposerAttachments }) {
  const { item, attachments } = props
  const status = useSignal(item.status)
  const failed = status.phase === "failed"
  const busy = status.phase === "staging" || status.phase === "uploading"
  const detail = statusText(status)
  // Shown without bidi controls (a dropped `invoice\u202Efdp.exe` reads as is) and in its own isolated element.
  const fileName = displayFileName(item.fileName)
  return (
    <li
      title={failed ? `${fileName}: ${detail}` : fileName}
      {...stylex.props(styles.chip, item.kind === "image" ? styles.imageChip : styles.fileChip, failed && styles.failedChip)}
    >
      {item.kind === "image" && item.thumbnailUrl !== undefined ? (
        <img src={item.thumbnailUrl} alt={fileName} draggable={false} decoding="async" {...stylex.props(styles.thumbnail)} />
      ) : (
        <>
          <span aria-hidden="true" {...stylex.props(styles.fileIcon)}>
            <FileIcon size={16} />
          </span>
          <span {...stylex.props(styles.fileText)}>
            <span dir="auto" {...stylex.props(styles.fileName)}>
              {fileName}
            </span>
            <span {...stylex.props(styles.fileMeta, failed && styles.failedText)}>{detail || item.sizeText}</span>
          </span>
        </>
      )}
      {item.kind === "image" && busy && (
        <span role="progressbar" aria-label={`Uploading ${fileName}`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={status.phase === "uploading" ? Math.round(status.fraction * 100) : 0} {...stylex.props(styles.ringLayer)}>
          <MiniRing fraction={status.phase === "uploading" ? status.fraction : 0} />
        </span>
      )}
      {failed && (
        <button
          type="button"
          aria-label={`Try ${fileName} again`}
          title={detail}
          onClick={() => attachments.retry(item.id)}
          {...stylex.props(styles.retry, item.kind === "image" ? styles.retryOverImage : styles.retryInline)}
        >
          <RetryIcon size={12} />
        </button>
      )}
      <button
        type="button"
        aria-label={`Remove ${fileName}`}
        title="Remove"
        onClick={() => attachments.remove(item.id)}
        {...stylex.props(styles.remove)}
      >
        <CloseIcon size={8} />
      </button>
    </li>
  )
})

/** A small progress ring; never empty while something is happening. */
function MiniRing(props: { fraction: number }) {
  const size = 24
  const r = 9.5
  const circumference = 2 * Math.PI * r
  const fraction = Math.max(0.04, Math.min(1, props.fraction))
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true" focusable="false" {...stylex.props(styles.ring)}>
      <circle cx={12} cy={12} r={r} fill="none" strokeWidth={2.5} {...stylex.props(styles.ringTrack)} />
      <circle
        cx={12}
        cy={12}
        r={r}
        fill="none"
        strokeWidth={2.5}
        strokeLinecap="round"
        strokeDasharray={circumference}
        strokeDashoffset={circumference * (1 - fraction)}
        {...stylex.props(styles.ringArc)}
      />
    </svg>
  )
}

const styles = stylex.create({
  region: {
    display: "flex",
    flexDirection: "column",
    gap: space.xs,
    paddingBlockStart: space.sm,
    paddingInline: space.sm,
    minInlineSize: 0,
    cursor: "default",
  },
  strip: {
    display: "flex",
    gap: space.sm,
    margin: 0,
    padding: 0,
    listStyle: "none",
    overflowX: "auto",
    overflowY: "hidden",
    overscrollBehaviorX: "contain",
    scrollbarWidth: "thin",
    minInlineSize: 0,
  },
  chip: {
    position: "relative",
    flexShrink: 0,
    boxSizing: "border-box",
    blockSize: `${CHIP}px`,
    borderRadius: radius.control,
    overflow: "hidden",
    backgroundColor: color.controlTrack,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: { default: color.separator, "@media (forced-colors: active)": "CanvasText" },
  },
  imageChip: { inlineSize: `${CHIP}px` },
  fileChip: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    minInlineSize: "150px",
    maxInlineSize: "220px",
    paddingInlineStart: space.sm,
    paddingInlineEnd: "24px",
  },
  failedChip: { borderColor: color.red },
  thumbnail: { display: "block", inlineSize: "100%", blockSize: "100%", objectFit: "cover" },
  fileIcon: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    inlineSize: "32px",
    blockSize: "32px",
    borderRadius: radius.pill,
    backgroundColor: color.accent,
    color: color.onAccent,
  },
  fileText: { display: "flex", flexDirection: "column", minInlineSize: 0, gap: "2px" },
  fileName: {
    fontSize: font.sizeCallout,
    fontWeight: font.weightMedium,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  fileMeta: {
    fontSize: font.sizeFootnote,
    color: color.secondaryLabel,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
    fontVariantNumeric: "tabular-nums",
  },
  failedText: { color: color.red },
  ringLayer: {
    position: "absolute",
    inset: 0,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "rgb(0 0 0 / 0.25)",
    color: "white",
    pointerEvents: "none",
  },
  ring: { transform: "rotate(-90deg)" },
  ringTrack: { stroke: "rgb(255 255 255 / 0.35)" },
  ringArc: {
    stroke: "currentColor",
    transitionProperty: "stroke-dashoffset",
    transitionDuration: motion.durationSlow,
    transitionTimingFunction: motion.easeOut,
  },
  retry: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: "24px",
    blockSize: "24px",
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: color.red,
    color: "white",
    cursor: "pointer",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "2px",
  },
  retryOverImage: {
    position: "absolute",
    insetBlockStart: "50%",
    insetInlineStart: "50%",
    transform: "translate(-50%, -50%)",
  },
  retryInline: { flexShrink: 0, marginInlineStart: "auto" },
  remove: {
    position: "absolute",
    insetBlockStart: "4px",
    insetInlineEnd: "4px",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: "16px",
    blockSize: "16px",
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: "rgb(0 0 0 / 0.55)",
    color: "white",
    cursor: "pointer",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
  notice: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    minInlineSize: 0,
    fontSize: font.sizeCallout,
    color: color.red,
  },
  noticeText: { flexGrow: 1, minInlineSize: 0 },
})
