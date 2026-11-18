/**
 * The composer's first-frame attachment views: the "Attach files" button,
 * the drop overlay a chat pane mounts, and `AttachmentStrip`, which renders
 * the strip (`AttachmentStripView`, its own chunk) once a file exists and
 * the chunk is here. They render `ComposerAttachments` and `DropTarget`
 * (framework-free); nothing here holds state that matters.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { useRef } from "react"
import type { ComposerAttachments } from "./attachments"
import type { DropTarget } from "./drop-target"
import { AttachIcon } from "./icons"
import { attachmentStripChunk } from "./strip-chunk"

/**
 * The strip, once a file exists: renders nothing until the attachments have
 * items or a notice and the strip's chunk is here (it loads on the first
 * file, `ComposerAttachments.add`), so the first frame carries none of it.
 */
export function AttachmentStrip(props: { attachments: ComposerAttachments }) {
  const items = useSignal(props.attachments.items)
  const notice = useSignal(props.attachments.notice)
  const chunk = useSignal(attachmentStripChunk.value)
  if ((items.length === 0 && notice === null) || !chunk) return null
  return <chunk.AttachmentStripView attachments={props.attachments} />
}

/**
 * "Attach files": opens the system file picker. Sits at the start of the
 * composer's row, the size of the send button.
 */
export function AttachButton(props: { attachments: ComposerAttachments; disabled?: boolean }) {
  const input = useRef<HTMLInputElement>(null)
  return (
    <>
      <IconButton
        label="Attach files"
        icon={<AttachIcon />}
        disabled={props.disabled}
        // Keep the caret in the editor when pressed with a pointer.
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => input.current?.click()}
        style={styles.attach}
      />
      <input
        ref={input}
        type="file"
        multiple
        hidden
        tabIndex={-1}
        aria-hidden="true"
        onChange={(event) => {
          const files = Array.from(event.currentTarget.files ?? [])
          event.currentTarget.value = ""
          if (files.length > 0) props.attachments.add(files)
        }}
      />
    </>
  )
}

/**
 * The drop target over a chat pane while files are dragged over it. Mount it
 * inside the element handed to `DropTarget.attach`; it covers its nearest
 * positioned ancestor and lets every pointer event through.
 */
export function DropOverlay(props: { target: DropTarget; label?: string }) {
  const active = useSignal(props.target.active)
  if (!active) return null
  return (
    <div aria-hidden="true" {...stylex.props(styles.overlay)}>
      <div {...stylex.props(styles.overlayFrame)}>
        <span {...stylex.props(styles.overlayIcon)}>
          <AttachIcon size={22} />
        </span>
        <span {...stylex.props(styles.overlayText)}>{props.label ?? "Drop files to attach them"}</span>
      </div>
    </div>
  )
}

/** Hands the chat pane's root to a drop target: `ref={useDropTarget(target)}`. */
export const useDropTarget = (target: DropTarget) => useElement(target)

const styles = stylex.create({
  attach: {
    flexShrink: 0,
    inlineSize: "28px",
    blockSize: "28px",
    marginBlock: "3px",
    marginInlineStart: "3px",
    borderRadius: radius.pill,
    color: color.secondaryLabel,
  },
  overlay: {
    position: "absolute",
    inset: 0,
    zIndex: 1,
    display: "flex",
    padding: space.md,
    boxSizing: "border-box",
    backgroundColor: `color-mix(in srgb, ${color.windowBackground} 70%, transparent)`,
    pointerEvents: "none",
  },
  overlayFrame: {
    flexGrow: 1,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: space.sm,
    borderWidth: "2px",
    borderStyle: "dashed",
    borderColor: color.accent,
    borderRadius: radius.content,
    color: color.accent,
  },
  overlayIcon: { display: "inline-flex" },
  overlayText: { fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
})
