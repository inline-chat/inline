/**
 * Attachments lab: the composer with its attachment strip and the drop
 * overlay, and a small timeline of media rows, over a scripted core
 * (`LabCore`) that plays the `media` and attachment resources. Images are
 * drawn on a canvas; nothing is fetched. The panel counts live object URLs
 * (media, attachment thumbnails and blurred previews); after "Remove all"
 * and the grace period it must read zero.
 *
 *   lab-attachments.html?appearance=dark&dir=rtl&auto=0
 *
 * Automation: `globalThis.__attachmentsLab` (state) and
 * `globalThis.__attachmentsLabControl` (controls). See
 * `web/src/features/media/README.md`.
 */

import type { MediaRef, MediaResource, MessageRow, UploadProgress } from "@inline/core-protocol"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import type { Appearance } from "@inline/ui/theme"
import { startDocumentAppearance } from "@inline/ui/theme/stylex"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import { createRoot } from "react-dom/client"
import { DropOverlay } from "../../features/composer/AttachmentStrip"
import { attachmentStripChunk } from "../../features/composer/strip-chunk"
import { pictureBlob } from "../content/pictures"
import { ComposerView } from "../../features/composer/ComposerView"
import { MessageContent } from "../../features/content/MessageContent"
import { AttachmentsLab, generatedFile, generatedImage } from "./lab"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const appearance = startDocumentAppearance()
const params = new URLSearchParams(location.search)
const startAppearance = params.get("appearance")
if (startAppearance === "light" || startAppearance === "dark" || startAppearance === "system") appearance.setAppearance(startAppearance)
document.documentElement.dir = params.get("dir") === "rtl" ? "rtl" : "ltr"

const lab = new AttachmentsLab()
if (params.get("auto") === "0") lab.core.auto.set(false)
void lab.seed()

/** A file that claims a size over the server's limit, without holding the bytes. */
const oversized = (): File => {
  const file = generatedFile("huge-video.mov", "video/quicktime", 16)
  Object.defineProperty(file, "size", { value: 600_000_000 })
  return file
}

// ---------------------------------------------------------------------------
// Automation surface

const control = {
  setAppearance: (value: Appearance) => appearance.setAppearance(value),
  setDirection: (value: "ltr" | "rtl") => {
    document.documentElement.dir = value
  },
  /** Downloads and uploads advance on timers (default) or only by these controls. */
  setAuto: (value: boolean) => lab.core.auto.set(value),
  pauseUploads: (paused: boolean) => lab.core.uploading.set(!paused),
  addImages: async (count = 1) => {
    const files = await Promise.all(Array.from({ length: count }, () => generatedImage()))
    lab.attachments.add(files)
  },
  addFile: (name = "notes.pdf", type = "application/pdf", bytes = 48_000) => lab.attachments.add([generatedFile(name, type, bytes)]),
  addOversized: () => lab.attachments.add([oversized()]),
  addEmpty: () => lab.attachments.add([new File([], "empty.txt", { type: "text/plain" })]),
  /** Drop files on the pane, as a drag from the desktop would. */
  dropImages: async (count = 1) => {
    const files = await Promise.all(Array.from({ length: count }, () => generatedImage()))
    lab.attachments.add(files)
  },
  removeAttachment: (index = 0) => {
    const item = lab.attachments.items.peek()[index]
    if (item) lab.attachments.remove(item.id)
  },
  retryAttachment: (index = 0) => {
    const item = lab.attachments.items.peek()[index]
    if (item) lab.attachments.retry(item.id)
  },
  /** Type a caption and send what the strip holds. Resolves with whether the composer cleared. */
  send: async (text = "") => {
    if (text) lab.composer.composer.insertText(text)
    return await lab.composer.composer.send()
  },
  /** A message's media: `queued`, `downloading` (with progress 0 to 1), `ready`, `failed`, `absent`. */
  setMedia: (messageId: string, state: MediaResource["state"], progress?: number) => lab.core.setMedia(messageId, state, progress),
  /** An attachment's upload (by attachment ID, or by index in the strip or among sending rows). */
  setUpload: (target: string | number, state: UploadProgress["state"], fraction?: number) => {
    const id = typeof target === "string" ? target : uploadIds()[target]
    if (id) lab.core.setUpload(id, state, fraction)
  },
  cancelSend: (rowIndex = 0) => sendingUpload(rowIndex)?.cancel(),
  resendSend: (rowIndex = 0) => sendingUpload(rowIndex)?.resend(),
  removeAll: () => lab.removeAll(),
  skipGrace: () => lab.skipGrace(),
  /** Start editing a message, so files pasted or dropped then can be checked (they join the strip, as on the Mac). */
  setEditing: (on: boolean) => {
    if (on) lab.composer.composer.startEdit({ messageId: "1" as never }, { text: "Editing a message" })
    else lab.composer.composer.cancelEdit()
  },
  /** Paste a file on the editor (what the binding does with a clipboard file). */
  pasteFile: async () => lab.composer.composer.pasteFiles([await generatedImage()]),
  /** Tiny and very wide images: both must go as files (`attachHints[].as`). */
  addOddImages: async () => {
    const tiny = await pictureBlob({ width: 40, height: 30, hue: 10, label: "" })
    const wide = await pictureBlob({ width: 2100, height: 100, hue: 90, label: "" })
    lab.attachments.add([new File([tiny], "icon.jpg", { type: tiny.type }), new File([wide], "banner.jpg", { type: wide.type })])
  },
  scrollTimeline: (to: "top" | "bottom" | number) => {
    const element = document.querySelector("[data-lab-timeline]")
    if (!element) return
    element.scrollTop = to === "top" ? 0 : to === "bottom" ? element.scrollHeight : to
  },
}

/** Attachments with an upload: the strip's, then sends still in flight. */
const uploadIds = (): string[] => [...lab.core.attachments.keys()]

const sendingRows = (): MessageRow[] => lab.core.rows.peek().filter((row) => row.upload !== undefined)

const sendingUpload = (index: number) => {
  const row = sendingRows()[index]
  if (!row?.upload) return undefined
  return lab.sources.upload({
    chatId: row.chatId,
    messageId: row.messageId,
    attachmentId: row.upload.attachmentId,
    clientKey: row.clientKey,
    state: row.state,
  })
}

const refText = (ref: MediaRef) => (ref.kind === "attachment" ? `attachment ${ref.attachmentId.slice(0, 6)}` : `message ${ref.messageId}`)

Object.assign(globalThis, {
  __attachmentsLab: {
    get urls() {
      return {
        live: lab.liveUrls(),
        media: lab.urls.live(),
        previews: lab.previewUrls.live(),
        created: lab.urls.created() + lab.previewUrls.created(),
        revoked: lab.urls.revoked() + lab.previewUrls.revoked(),
      }
    },
    get sources() {
      return lab.sources.stats()
    },
    get rows() {
      return lab.core.rows.peek().map((row) => ({
        id: row.id,
        messageId: row.messageId,
        state: row.state,
        media: row.media?.kind,
        uploading: row.upload !== undefined,
      }))
    },
    get attachments() {
      return lab.attachments.items.peek().map((item) => ({
        id: item.id,
        fileName: item.fileName,
        kind: item.kind,
        status: item.status.peek(),
      }))
    },
    get notice() {
      return lab.attachments.notice.peek()
    },
    get composerError() {
      return lab.composer.errorText.peek()
    },
    get hints() {
      return lab.core.hints.peek().map(refText)
    },
    get subscriptions() {
      return [...lab.core.subs.entries()].map(([sub, { ref, priority }]) => ({ sub, ref: refText(ref), priority }))
    },
    get heightChanges() {
      return lab.heightChanges.peek()
    },
    /** What the composer's probe added to each attachFile: size, length, preview bytes, `as: "document"` (the Mac's small or wide rule). */
    get attachHints() {
      return lab.core.attachHints.peek()
    },
    /** The upload activity the chat pane would report (`ComposerAttachments.activity`). */
    get activity() {
      return lab.attachments.activity?.peek() ?? null
    },
    /** The strip's view chunk is loaded (it loads on the first file). */
    get stripLoaded() {
      return attachmentStripChunk.value.peek() !== undefined
    },
    get editing() {
      return lab.composer.composer.editing.peek() !== null
    },
    /** Each own photo row's image URL now: it must stay the local one until the server copy is ready. */
    get ownPhotoUrls() {
      return lab.core.rows
        .peek()
        .filter((row) => row.out && row.media?.kind === "photo")
        .map((row) => {
          const media = row.media
          if (media?.kind !== "photo") return null
          const state = lab.sources
            .photo(media.photo, { width: 320, height: 240 }, { chatId: row.chatId, messageId: row.messageId, attachmentId: row.upload?.attachmentId, clientKey: row.clientKey, state: row.state })
            .state.peek()
          return { id: row.id, sending: row.upload !== undefined, url: state.status === "ready" ? state.url : state.status }
        })
    },
    get log() {
      return lab.core.log.peek()
    },
  },
  __attachmentsLabControl: control,
})

// ---------------------------------------------------------------------------
// Views

function Lab() {
  const dropRef = useElement(lab.drop)
  return (
    <div {...stylex.props(styles.page)}>
      <Panel />
      <div ref={dropRef} {...stylex.props(styles.pane)}>
        <Timeline />
        <div {...stylex.props(styles.composer)}>
          <ComposerView model={lab.composer} attachments={lab.attachments} placeholder="Message" />
        </div>
        <DropOverlay target={lab.drop} />
      </div>
      <Log />
    </div>
  )
}

function Timeline() {
  const rows = useSignal(lab.core.rows)
  const ref = useElement(lab.visibility)
  return (
    <div ref={ref} data-lab-timeline="" {...stylex.props(styles.timeline)}>
      {rows.map((row) => (
        <TimelineRow key={row.id} row={row} />
      ))}
    </div>
  )
}

const TimelineRow = memo(function TimelineRow(props: { row: MessageRow }) {
  const { row } = props
  const measure = useModel(() => lab.measureRow(row.id), [row.id])
  const ref = useElement(measure)
  return (
    <div ref={ref} data-row={row.id} {...stylex.props(styles.row, row.out && styles.rowOut)}>
      <div {...stylex.props(styles.bubble, row.out ? styles.bubbleOut : styles.bubbleIn)}>
        <MessageContent message={row} env={lab.env} />
        {row.text && (
          <div dir="auto" {...stylex.props(styles.text)}>
            {row.text}
          </div>
        )}
        <div {...stylex.props(styles.meta)}>
          {row.messageId ? `#${row.messageId}` : "local"} · {row.state}
        </div>
      </div>
      {!row.out && row.messageId && <MediaButtons messageId={row.messageId} />}
    </div>
  )
})

function MediaButtons(props: { messageId: string }) {
  const id = props.messageId
  return (
    <div {...stylex.props(styles.buttons)}>
      <LabButton label="Queued" onClick={() => void control.setMedia(id, "queued")} />
      <LabButton label="30%" onClick={() => void control.setMedia(id, "downloading", 0.3)} />
      <LabButton label="70%" onClick={() => void control.setMedia(id, "downloading", 0.7)} />
      <LabButton label="Ready" onClick={() => void control.setMedia(id, "ready")} />
      <LabButton label="Failed" onClick={() => void control.setMedia(id, "failed")} />
      <LabButton label="Absent" onClick={() => void control.setMedia(id, "absent")} />
    </div>
  )
}

function LabButton(props: { label: string; onClick: () => void }) {
  return (
    <button type="button" onClick={props.onClick} {...stylex.props(styles.button)}>
      {props.label}
    </button>
  )
}

function Panel() {
  useSignal(lab.tick)
  const auto = useSignal(lab.core.auto)
  const uploading = useSignal(lab.core.uploading)
  const changes = useSignal(lab.heightChanges)
  const hints = useSignal(lab.core.hints)
  useSignal(lab.core.rows)
  const stats = lab.sources.stats()
  const live = lab.liveUrls()
  return (
    <div {...stylex.props(styles.panel)}>
      <strong {...stylex.props(styles.title)}>Attachments lab</strong>
      <span data-lab-live-urls={live} {...stylex.props(styles.counter, live === 0 && styles.counterZero)}>
        Live object URLs: {live} (media and thumbnails {lab.urls.live()}, previews {lab.previewUrls.live()})
      </span>
      <span {...stylex.props(styles.stat)}>
        Entries {stats.entries} · held {stats.held} · subscribed {stats.subscribed} · idle {stats.idle} · nearby hints {hints.length}
      </span>
      <span {...stylex.props(styles.stat, changes.length > 0 && styles.bad)}>Row height changes: {changes.length}</span>
      <div {...stylex.props(styles.buttons)}>
        <LabButton label={auto ? "Auto: on" : "Auto: off"} onClick={() => control.setAuto(!auto)} />
        <LabButton label={uploading ? "Pause uploads" : "Resume uploads"} onClick={() => control.pauseUploads(uploading)} />
        <LabButton label="Add image" onClick={() => void control.addImages(1)} />
        <LabButton label="Add 3 images" onClick={() => void control.addImages(3)} />
        <LabButton label="Add PDF" onClick={() => control.addFile()} />
        <LabButton label="Add 600 MB file" onClick={() => control.addOversized()} />
        <LabButton label="Add empty file" onClick={() => control.addEmpty()} />
        <LabButton label="Upload 50%" onClick={() => control.setUpload(0, "uploading", 0.5)} />
        <LabButton label="Upload done" onClick={() => control.setUpload(0, "complete")} />
        <LabButton label="Upload fails" onClick={() => control.setUpload(0, "failed")} />
        <LabButton label="Cancel send" onClick={() => control.cancelSend(0)} />
        <LabButton label="Resend" onClick={() => control.resendSend(0)} />
        <LabButton label="Remove all" onClick={() => control.removeAll()} />
        <LabButton label="Skip grace" onClick={() => control.skipGrace()} />
      </div>
    </div>
  )
}

function Log() {
  const log = useSignal(lab.core.log)
  return (
    <ol aria-label="Core log" {...stylex.props(styles.log)}>
      {log.slice(-24).map((entry, index) => (
        <li key={`${entry.at}-${index}`}>
          {entry.at} {entry.text}
        </li>
      ))}
    </ol>
  )
}

const styles = stylex.create({
  page: {
    display: "grid",
    gridTemplateColumns: "minmax(0, 1fr)",
    gap: space.md,
    maxInlineSize: "760px",
    marginInline: "auto",
    padding: space.lg,
    minBlockSize: "100vh",
    boxSizing: "border-box",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  panel: { display: "flex", flexDirection: "column", gap: space.xs },
  title: { fontSize: font.sizeTitle3 },
  counter: { fontVariantNumeric: "tabular-nums", fontWeight: font.weightSemibold },
  counterZero: { color: color.green },
  stat: { fontSize: font.sizeCallout, color: color.secondaryLabel, fontVariantNumeric: "tabular-nums" },
  bad: { color: color.red },
  buttons: { display: "flex", flexWrap: "wrap", gap: space.xs },
  button: {
    paddingBlock: "2px",
    paddingInline: space.sm,
    fontSize: font.sizeCallout,
    borderRadius: radius.control,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    backgroundColor: color.control,
    color: color.controlText,
    cursor: "pointer",
  },
  pane: {
    position: "relative",
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.content,
    padding: space.sm,
  },
  timeline: {
    blockSize: "460px",
    overflowY: "auto",
    overflowAnchor: "none",
    display: "flex",
    flexDirection: "column",
    gap: space.md,
    paddingInline: space.sm,
  },
  row: { display: "flex", flexDirection: "column", alignItems: "flex-start", gap: space.xxs },
  rowOut: { alignItems: "flex-end" },
  bubble: {
    display: "flex",
    flexDirection: "column",
    gap: space.xs,
    maxInlineSize: "380px",
    padding: space.xs,
    borderRadius: radius.bubble,
  },
  bubbleIn: { backgroundColor: color.secondaryBubble, color: color.secondaryBubbleText },
  bubbleOut: { backgroundColor: color.bubble, color: color.onAccent },
  text: { paddingInline: space.xs },
  meta: { paddingInline: space.xs, fontSize: font.sizeFootnote, opacity: 0.7 },
  composer: { flexShrink: 0 },
  log: {
    margin: 0,
    paddingInlineStart: space.lg,
    fontFamily: font.familyMono,
    fontSize: font.sizeFootnote,
    color: color.secondaryLabel,
  },
})

const root = document.getElementById("root")
if (root) createRoot(root).render(<Lab />)
