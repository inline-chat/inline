/**
 * One shared-media tab: a grid of square cells for photos and videos (the
 * Mac's adaptive grid, 100 px minimum, 4 px gaps), rows for files, voice
 * and links, and the footer (loading, Load More, failed with Retry, empty).
 * Cells reserve their square before anything loads, so nothing shifts.
 * Each cell and row reads only its own item.
 */

import type { RowKey } from "@inline/core-protocol"
import { useElement, useSignal } from "@inline/reactive/react"
import { Button } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import type { ChatInfoModel } from "./chat-info-model"
import type { ChatMediaModel, ChatMediaTabId } from "./chat-media-model"

/** The box a cell asks a photo variant for. */
const CELL_BOX = { width: 160, height: 160 }

export function ChatMediaTab(props: { model: ChatInfoModel; tab: ChatMediaTabId }) {
  const media = props.model.mediaTab(props.tab)
  const ids = useSignal(media.ids)
  const sentinelRef = useElement(media.sentinel)
  return (
    <div {...stylex.props(styles.panel)}>
      {props.tab === "media" ? (
        <MediaGrid model={props.model} media={media} ids={ids} />
      ) : ids.length > 0 ? (
        <ul aria-label={tabLabels[props.tab]} {...stylex.props(styles.rows)}>
          {ids.map((key) => (
            <MediaRow key={key} model={props.model} media={media} id={key} />
          ))}
        </ul>
      ) : null}
      <span ref={sentinelRef} aria-hidden="true" {...stylex.props(styles.sentinel)} />
      <Footer media={media} />
    </div>
  )
}

const tabLabels: Record<ChatMediaTabId, string> = { media: "Photos and videos", files: "Files", voice: "Voice memos", links: "Links" }

function MediaGrid(props: { model: ChatInfoModel; media: ChatMediaModel; ids: readonly RowKey[] }) {
  const gridRef = useElement(props.model.mediaGrid.root)
  const visibilityRef = useElement(props.model.mediaVisibility)
  if (props.ids.length === 0) return null
  return (
    <div ref={visibilityRef}>
      <ul ref={gridRef} aria-label="Photos and videos" {...stylex.props(styles.grid)}>
        {props.ids.map((key, index) => (
          <MediaCell key={key} model={props.model} media={props.media} id={key} index={index} />
        ))}
      </ul>
    </div>
  )
}

const MediaCell = memo(function MediaCell(props: { model: ChatInfoModel; media: ChatMediaModel; id: RowKey; index: number }) {
  const item = useSignal(props.media.item(props.id))
  const tabStop = useSignal(props.model.mediaGrid.isTabStop(props.index))
  const cellRef = useElement(props.model.mediaGrid.cell(props.index))
  const sources = props.model.media?.sources
  const photo = item?.kind === "media" ? item.photo : undefined
  const source = photo && sources && item ? sources.photo(photo, CELL_BOX, item.owner, item.kind === "media" && item.video !== undefined) : undefined
  return (
    <li {...stylex.props(styles.cellItem)}>
      <button
        ref={cellRef}
        type="button"
        tabIndex={tabStop ? 0 : -1}
        aria-label={item?.kind === "media" ? item.label : "Media"}
        onClick={() => props.model.mediaGrid.open(props.index)}
        {...stylex.props(styles.cell, styles.focusRing)}
      >
        {source ? <Thumbnail source={source} /> : null}
        {item?.kind === "media" && item.durationText ? <span {...stylex.props(styles.duration)}>{item.durationText}</span> : null}
      </button>
    </li>
  )
})

type Source = NonNullable<ReturnType<NonNullable<ChatInfoModel["media"]>["sources"]["photo"]>>

function Thumbnail(props: { source: Source }) {
  const state = useSignal(props.source.state)
  const holdRef = useElement(props.source.part ?? noPart)
  return (
    <span ref={holdRef} {...stylex.props(styles.thumbnailBox)}>
      {state.status === "ready" ? <img src={state.url} alt="" draggable={false} decoding="async" {...stylex.props(styles.thumbnail)} /> : null}
    </span>
  )
}

const noPart = { attach: () => () => {} }

const MediaRow = memo(function MediaRow(props: { model: ChatInfoModel; media: ChatMediaModel; id: RowKey }) {
  const item = useSignal(props.media.item(props.id))
  if (!item) return null
  const handlers = props.model.media
  switch (item.kind) {
    case "file":
      return (
        <li {...stylex.props(styles.row)}>
          <span aria-hidden="true" {...stylex.props(styles.badge)}>
            {item.typeText}
          </span>
          <span {...stylex.props(styles.rowText)}>
            <span dir="auto" {...stylex.props(styles.rowTitle)}>
              {item.fileName}
            </span>
            <span {...stylex.props(styles.rowSubtitle)}>
              {item.sizeText} · {item.dateText}
            </span>
          </span>
          {handlers?.onDownload ? (
            <Button size="small" aria-label={`Download ${item.fileName}`} onClick={() => handlers.onDownload?.({ rowId: item.rowId, media: item.media })}>
              Download
            </Button>
          ) : null}
        </li>
      )
    case "voice":
      return (
        <li {...stylex.props(styles.row)}>
          <span aria-hidden="true" {...stylex.props(styles.badge)}>
            ♪
          </span>
          <span {...stylex.props(styles.rowText)}>
            <span {...stylex.props(styles.rowTitle)}>Voice memo</span>
            <span dir="auto" {...stylex.props(styles.rowSubtitle)}>
              {item.senderName} · {item.dateText}
            </span>
          </span>
          <span {...stylex.props(styles.rowMeta)}>{item.durationText}</span>
        </li>
      )
    case "link":
      return (
        <li {...stylex.props(styles.row)}>
          <span aria-hidden="true" {...stylex.props(styles.badge)}>
            ↗
          </span>
          <span {...stylex.props(styles.rowText)}>
            {item.url ? (
              <a
                href={item.url}
                target="_blank"
                rel="noopener noreferrer"
                dir="auto"
                onClick={(event) => {
                  if (!handlers?.onOpenLink || !item.url) return
                  event.preventDefault()
                  handlers.onOpenLink(item.url)
                }}
                {...stylex.props(styles.rowTitle, styles.link, styles.focusRing)}
              >
                {item.title}
              </a>
            ) : (
              <span dir="auto" {...stylex.props(styles.rowTitle)}>
                {item.title}
              </span>
            )}
            {item.subtitle ? (
              <span dir="auto" {...stylex.props(styles.rowSubtitle)}>
                {item.subtitle}
              </span>
            ) : null}
          </span>
        </li>
      )
    case "media":
      return null
  }
})

function Footer(props: { media: ChatMediaModel }) {
  const footer = useSignal(props.media.footer)
  switch (footer.kind) {
    case "pending":
    case "end":
      return <p role="status" {...stylex.props(styles.footer)} />
    case "loading":
      return (
        <p role="status" {...stylex.props(styles.footer)}>
          {footer.empty ? "Loading history…" : "Loading…"}
        </p>
      )
    case "more":
      return (
        <div {...stylex.props(styles.footer)}>
          <Button size="small" onClick={() => props.media.loadMore()}>
            Load More
          </Button>
        </div>
      )
    case "failed":
      return (
        <div role="alert" {...stylex.props(styles.footer)}>
          <span>Couldn't load history.</span>
          <Button size="small" onClick={() => props.media.retry()}>
            Retry
          </Button>
        </div>
      )
    case "empty":
      return (
        <p role="status" {...stylex.props(styles.footer)}>
          {footer.text}
        </p>
      )
  }
}

const styles = stylex.create({
  panel: { display: "flex", flexDirection: "column", gap: space.md, minInlineSize: 0 },
  grid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fill, minmax(100px, 1fr))",
    // `MEDIA_CELL_MIN` and `MEDIA_CELL_GAP` in media-grid.ts (StyleX needs literals here).
    gap: "4px",
    margin: 0,
    padding: 0,
    listStyle: "none",
  },
  cellItem: { display: "block", minInlineSize: 0 },
  cell: {
    position: "relative",
    display: "block",
    inlineSize: "100%",
    // The square is reserved before anything loads: no layout shift.
    aspectRatio: "1",
    padding: 0,
    borderWidth: 0,
    borderRadius: radius.control,
    overflow: "hidden",
    backgroundColor: color.controlTrack,
    cursor: "pointer",
    contentVisibility: "auto",
    containIntrinsicSize: "auto 100px",
  },
  focusRing: {
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
  thumbnailBox: { position: "absolute", inset: 0, display: "block" },
  thumbnail: { display: "block", inlineSize: "100%", blockSize: "100%", objectFit: "cover" },
  duration: {
    position: "absolute",
    insetBlockEnd: space.xs,
    insetInlineEnd: space.xs,
    paddingInline: space.xs,
    borderRadius: radius.menuItem,
    backgroundColor: "rgb(0 0 0 / 0.55)",
    color: "white",
    fontSize: font.sizeFootnote,
    fontVariantNumeric: "tabular-nums",
  },
  rows: { display: "flex", flexDirection: "column", margin: 0, padding: 0, listStyle: "none" },
  row: {
    display: "flex",
    alignItems: "center",
    gap: space.lg,
    minBlockSize: "48px",
    paddingInline: space.md,
    paddingBlock: space.sm,
    borderBlockEndWidth: space.hairline,
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
    contentVisibility: "auto",
    containIntrinsicSize: "auto 48px",
  },
  badge: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    inlineSize: "36px",
    blockSize: "36px",
    borderRadius: radius.control,
    backgroundColor: color.controlTrack,
    color: color.secondaryLabel,
    fontSize: font.sizeFootnote,
    fontWeight: font.weightSemibold,
  },
  rowText: { display: "flex", flexDirection: "column", minInlineSize: 0, flexGrow: 1 },
  rowTitle: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", minInlineSize: 0 },
  rowSubtitle: { color: color.secondaryLabel, fontSize: font.sizeCallout, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  rowMeta: { color: color.secondaryLabel, fontSize: font.sizeCallout, fontVariantNumeric: "tabular-nums", flexShrink: 0 },
  link: { color: color.link, textDecoration: { default: "none", ":hover": "underline" } },
  sentinel: { display: "block", blockSize: "1px" },
  footer: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.md,
    margin: 0,
    minBlockSize: "2.5em",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
  },
})
