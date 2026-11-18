/**
 * Photos, videos, GIFs, stickers, block images, albums, documents and voice
 * notes. Every box has its final size from the model before a byte loads:
 * width from the model, height from its aspect ratio (so a narrow column
 * scales it down without reflow later). The blurred preview paints from the
 * row's bytes at once; the image fades in after it decodes, inside the same
 * box. Loading and failing never change the box.
 */

import * as stylex from "@stylexjs/stylex"
import {
  type AlbumLayout,
  type Box,
  type DocumentRowModel,
  type ImageNode,
  type VisualMediaModel,
  type VoiceRowModel,
  formatDuration,
} from "@inline/chat-ui"
import type { MediaContent, PhotoInfo } from "@inline/core-protocol"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { type KeyboardEvent, memo, type PointerEvent, type ReactNode } from "react"
import type { OpenMediaInput } from "./env"
import { displayFileName, splitFileName } from "./file-name"
import { DownloadIcon, FileKindIcon, ImageOffIcon, PauseIcon, PlayIcon, RetryIcon } from "./icons"
import { RevealController, type RevealStatus } from "./reveal"
import type { RowContent } from "./row-content"
import { constantSource, type ElementPart, type MediaOwner, type MediaSource, type MediaSourceState } from "./sources"
import { showsUpload } from "./upload"
import { UploadOverlay } from "./UploadOverlay"
import { VoicePlayerController } from "./voice-player"

const MEDIA_RADIUS = "13px" // mediaMetrics.cornerRadius

// ---------------------------------------------------------------------------
// The layered box: preview, image, overlays

const pendingSource: MediaSource = constantSource({ status: "pending" })

const noPart: ElementPart = { attach: () => () => {} }
const holdParts = new WeakMap<ElementPart, WeakMap<ElementPart, ElementPart>>()

/**
 * One part that hands the media box to every source shown in it (a GIF's
 * thumbnail and its video), so the media layer holds them while the box is
 * on the page. Cached per pair, so `useElement` keeps its ref callback.
 */
const holdPart = (first: MediaSource | undefined, second?: MediaSource): ElementPart => {
  const a = first?.part
  const b = second?.part
  if (!a || !b) return a ?? b ?? noPart
  let byFirst = holdParts.get(a)
  if (!byFirst) {
    byFirst = new WeakMap()
    holdParts.set(a, byFirst)
  }
  let part = byFirst.get(b)
  if (!part) {
    part = {
      attach: (element) => {
        const releaseA = a.attach(element)
        const releaseB = b.attach(element)
        return () => {
          releaseB()
          releaseA()
        }
      },
    }
    byFirst.set(b, part)
  }
  return part
}

type RevealInput = {
  ctx: RowContent
  /** Model key, for debug hooks. */
  mediaKey: string
  photo: PhotoInfo | undefined
  box: Box
  /** The message the photo belongs to, when it is the message's own media. */
  owner?: MediaOwner | undefined
  thumbnail?: boolean
}

type RevealedImage = {
  readonly reveal: RevealController
  readonly status: RevealStatus
  readonly url: string | undefined
  /** The media layer's source: hand the box to its `part`. */
  readonly source: MediaSource
  retry(): void
}

/** A photo's source and its reveal: the status combines the media layer's and the element's. */
function useRevealedImage(input: RevealInput): RevealedImage {
  const { ctx } = input
  const source = input.photo ? ctx.env.sources.photo(input.photo, input.box, input.owner, input.thumbnail) : pendingSource
  const state: MediaSourceState = useSignal(source.state)
  const url = state.status === "ready" ? state.url : undefined
  const debug = ctx.env.debug?.onMediaStatus
  const reveal = useModel(
    () =>
      new RevealController({
        url,
        loaded: ctx.env.loaded,
        ...(debug ? { onStatus: (status: RevealStatus) => debug(ctx.rowId, input.mediaKey, status) } : {}),
      }),
    [url],
  )
  const revealStatus = useSignal(reveal.status)
  return {
    reveal,
    url,
    source,
    status: state.status === "failed" ? "failed" : revealStatus,
    retry: () => {
      source.retry()
      reveal.retry()
    },
  }
}

/** The preview and image layers, absolutely filling their box. */
function ImageLayers(props: { ctx: RowContent; preview: Uint8Array | undefined; image: RevealedImage; fit: "cover" | "contain"; label?: string }) {
  const { image } = props
  const previewRef = useElement<HTMLSpanElement>(props.ctx.env.previews.part(props.preview))
  const revealRef = useElement<HTMLImageElement>(image.reveal.part)
  return (
    <>
      <span ref={previewRef} aria-hidden="true" {...stylex.props(styles.layer, styles.preview)} />
      {image.url !== undefined && (
        <img
          ref={revealRef}
          alt={props.label ?? ""}
          draggable={false}
          decoding="async"
          {...stylex.props(
            styles.layer,
            props.fit === "contain" ? styles.contain : styles.cover,
            styles.image,
            image.status === "loaded" && styles.shown,
            image.reveal.instant && styles.instant,
          )}
        />
      )}
    </>
  )
}

function RetryOverlay(props: { onRetry: () => void }) {
  return (
    <button
      type="button"
      aria-label="Couldn’t load. Try again"
      title="Couldn’t load. Try again"
      onClick={(event) => {
        event.stopPropagation()
        props.onRetry()
      }}
      {...stylex.props(styles.retry)}
    >
      <RetryIcon />
    </button>
  )
}

const boxStyle = (box: Box) => dynamic.box(box.width, box.height)

/**
 * A photo in a box of known size with no interaction of its own, for use
 * inside links and cards (link previews, document thumbnails). A failed load
 * leaves the preview; the retry affordance belongs to standalone media.
 */
export function PhotoBox(props: {
  ctx: RowContent
  mediaKey: string
  photo: PhotoInfo | undefined
  preview: Uint8Array | undefined
  box: Box
  /** `aspect`: the width, and the height from the ratio (scales in a narrow column). `fixed`: both. */
  sizing: "aspect" | "fixed"
  radius?: "media" | "small" | "none"
  children?: ReactNode
}) {
  const image = useRevealedImage({ ctx: props.ctx, mediaKey: props.mediaKey, photo: props.photo, box: props.box })
  const holdRef = useElement(holdPart(image.source))
  return (
    <span
      ref={holdRef}
      data-media-box={props.mediaKey}
      {...stylex.props(
        styles.box,
        props.sizing === "fixed" ? dynamic.fixed(props.box.width, props.box.height) : boxStyle(props.box),
        props.radius === "small" ? styles.roundedSmall : props.radius === "none" ? null : styles.rounded,
        styles.surface,
      )}
    >
      <ImageLayers ctx={props.ctx} preview={props.preview} image={image} fit="cover" />
      {props.children}
    </span>
  )
}

/** The play glyph over a video thumbnail. */
export function PlayBadge() {
  return (
    <span aria-hidden="true" {...stylex.props(styles.play)}>
      <PlayIcon size={18} />
    </span>
  )
}

// ---------------------------------------------------------------------------
// Photo, video, GIF, sticker

export const VisualMedia = memo(function VisualMedia(props: {
  media: VisualMediaModel
  ctx: RowContent
  /** The message this media belongs to (`RowContent.mediaOwner`); without it the layer cannot ask the core. */
  owner?: MediaOwner | undefined
}) {
  const { media, ctx, owner } = props
  const open = ctx.env.handlers.onOpenMedia
  const input: OpenMediaInput = {
    rowId: ctx.rowId,
    key: media.key,
    kind: media.kind,
    photo: media.photo,
    video: media.video,
  }
  const label = media.sticker ? "Sticker" : media.kind === "photo" ? "Photo" : media.kind === "gif" ? "GIF" : "Video"
  const image = useRevealedImage({
    ctx,
    mediaKey: media.key,
    photo: media.photo,
    box: media.box,
    owner,
    thumbnail: media.kind !== "photo",
  })
  const gifSource = media.kind === "gif" && media.video ? ctx.env.sources.video(media.video, owner) : undefined
  const holdRef = useElement(holdPart(image.source, gifSource))
  const upload = owner && showsUpload(owner.state) ? ctx.env.sources.upload?.(owner) : undefined
  return (
    <div
      ref={holdRef}
      data-media-box={media.key}
      data-media-kind={media.kind}
      {...stylex.props(styles.box, boxStyle(media.box), !media.sticker && styles.rounded, !media.noBubble && styles.surface)}
    >
      <button
        type="button"
        aria-label={media.durationText ? `${label}, ${media.durationText}` : label}
        disabled={!open}
        onClick={open ? () => open(input) : undefined}
        {...stylex.props(styles.cover, styles.hit)}
      >
        <ImageLayers ctx={ctx} preview={media.preview} image={image} fit={media.sticker ? "contain" : "cover"} />
        {gifSource && <GifLayer ctx={ctx} source={gifSource} />}
        {media.kind === "video" && !upload && (
          <span aria-hidden="true" {...stylex.props(styles.play)}>
            <PlayIcon size={18} />
          </span>
        )}
        {media.durationText && (
          <span aria-hidden="true" {...stylex.props(styles.badge)}>
            {media.durationText}
          </span>
        )}
        {media.kind === "gif" && (
          <span aria-hidden="true" {...stylex.props(styles.badge)}>
            GIF
          </span>
        )}
      </button>
      {upload && owner ? (
        <UploadOverlay upload={upload} state={owner.state} variant="media" noun={label.toLowerCase()} />
      ) : (
        image.status === "failed" && <RetryOverlay onRetry={image.retry} />
      )}
    </div>
  )
})

/** A GIF's muted, looping video over its thumbnail. Not mounted under reduced motion. */
function GifLayer(props: { ctx: RowContent; source: MediaSource }) {
  const { ctx, source } = props
  const state = useSignal(source.state)
  const url = state.status === "ready" ? state.url : undefined
  const reveal = useModel(() => new RevealController({ url, kind: "video", loaded: ctx.env.loaded }), [url])
  const status = useSignal(reveal.status)
  const part = useModel(
    () => ({
      attach: (element: HTMLVideoElement) => {
        const stopReveal = reveal.part.attach(element)
        const stopPlayback = ctx.env.gif.part.attach(element)
        return () => {
          stopPlayback()
          stopReveal()
        }
      },
    }),
    [reveal],
  )
  const ref = useElement(part)
  if (url === undefined || !ctx.env.gif.animate) return null
  return (
    <video
      ref={ref}
      muted
      loop
      playsInline
      preload="metadata"
      aria-hidden="true"
      tabIndex={-1}
      {...stylex.props(styles.layer, styles.cover, styles.image, status === "loaded" && styles.shown, reveal.instant && styles.instant)}
    />
  )
}

// ---------------------------------------------------------------------------
// Block images and albums

export const BlockImage = memo(function BlockImage(props: {
  image: ImageNode
  ctx: RowContent
  fixed?: boolean
  index?: number
}) {
  const { image, ctx } = props
  const open = ctx.env.handlers.onOpenMedia
  const canOpen = open !== undefined && image.state === "ready"
  const revealed = useRevealedImage({
    ctx,
    mediaKey: image.key,
    photo: image.state === "ready" ? image.photo : undefined,
    box: image.box,
  })
  const holdRef = useElement(holdPart(revealed.source))
  return (
    <div
      ref={holdRef}
      data-media-box={image.key}
      data-media-kind="image"
      {...stylex.props(
        styles.box,
        props.fixed ? dynamic.fixed(image.box.width, image.box.height) : boxStyle(image.box),
        styles.rounded,
        styles.surface,
      )}
    >
      {image.state === "unavailable" ? (
        <span role="img" aria-label={image.alt ?? "Image unavailable"} {...stylex.props(styles.cover, styles.unavailable)}>
          <ImageOffIcon />
        </span>
      ) : (
        <button
          type="button"
          aria-label={image.alt ?? "Image"}
          disabled={!canOpen}
          onClick={
            canOpen
              ? () =>
                  open({
                    rowId: ctx.rowId,
                    key: image.key,
                    kind: "image",
                    photo: image.photo,
                    video: undefined,
                    ...(props.index !== undefined ? { index: props.index } : {}),
                  })
              : undefined
          }
          {...stylex.props(styles.cover, styles.hit)}
        >
          <ImageLayers
            ctx={ctx}
            preview={image.preview}
            image={revealed}
            fit="cover"
            {...(image.alt ? { label: image.alt } : {})}
          />
        </button>
      )}
      {revealed.status === "failed" && <RetryOverlay onRetry={revealed.retry} />}
    </div>
  )
})

export function Album(props: { images: readonly ImageNode[]; layout: AlbumLayout; ctx: RowContent }) {
  return (
    <div role="group" aria-label={`Album, ${props.images.length} images`} {...stylex.props(styles.albumScroller)}>
      <div {...stylex.props(styles.albumStrip, dynamic.fixed(props.layout.width, props.layout.height))}>
        {props.images.map((image, index) => {
          const item = props.layout.items[index]
          if (!item) return null
          return (
            <BlockImage
              key={image.key}
              image={{ ...image, box: { width: item.width, height: item.height } }}
              ctx={props.ctx}
              fixed
              index={index}
            />
          )
        })}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Document row

const thumbnailBox: Box = { width: 70, height: 70 }

export const DocumentRow = memo(function DocumentRow(props: {
  model: DocumentRowModel & { readonly key: string }
  raw: MediaContent
  ctx: RowContent
  owner?: MediaOwner | undefined
}) {
  const { model, ctx, owner } = props
  const download = ctx.env.handlers.onDownload
  const displayName = displayFileName(model.name)
  const name = splitFileName(model.name)
  const thumbnail = props.raw.kind === "document" && model.hasThumbnail ? props.raw.document.thumbnail : undefined
  const outgoing = ctx.tone === "outgoing"
  const revealed = useRevealedImage({
    ctx,
    mediaKey: `${model.key}:thumbnail`,
    photo: thumbnail,
    box: thumbnailBox,
    owner,
    thumbnail: true,
  })
  const holdRef = useElement(holdPart(revealed.source))
  const upload = owner && showsUpload(owner.state) ? ctx.env.sources.upload?.(owner) : undefined
  return (
    <div
      ref={holdRef}
      data-media-box={model.key}
      data-media-kind="document"
      {...stylex.props(styles.documentRow, dynamic.documentHeight(model.height, model.minWidth))}
    >
      {thumbnail ? (
        <span {...stylex.props(styles.box, styles.documentThumbnail)}>
          <ImageLayers ctx={ctx} preview={undefined} image={revealed} fit="cover" />
          {upload && owner ? (
            <UploadOverlay upload={upload} state={owner.state} variant="media" noun="file" />
          ) : (
            revealed.status === "failed" && <RetryOverlay onRetry={revealed.retry} />
          )}
        </span>
      ) : upload && owner ? (
        <UploadOverlay upload={upload} state={owner.state} variant="file" noun="file" />
      ) : (
        <span aria-hidden="true" {...stylex.props(styles.fileIcon, outgoing && styles.fileIconOutgoing)}>
          <FileKindIcon icon={model.icon} />
        </span>
      )}
      <span {...stylex.props(styles.documentText)}>
        <span title={displayName} dir="auto" {...stylex.props(styles.fileName)}>
          <span {...stylex.props(styles.fileHead)}>{name.head}</span>
          {name.tail && <span {...stylex.props(styles.fileTail)}>{name.tail}</span>}
        </span>
        <span {...stylex.props(styles.fileMeta, outgoing ? styles.onAccentSecondary : styles.secondary)}>
          {model.sizeText}
        </span>
      </span>
      <IconButton
        label={`Download ${displayName}`}
        icon={<DownloadIcon />}
        size="small"
        disabled={!download}
        onClick={download ? () => download({ rowId: ctx.rowId, media: props.raw }) : undefined}
        style={outgoing ? styles.onAccentControl : undefined}
      />
    </div>
  )
})

// ---------------------------------------------------------------------------
// Voice note

export const VoiceRow = memo(function VoiceRow(props: {
  model: VoiceRowModel & { readonly key: string }
  raw: MediaContent
  ctx: RowContent
  owner?: MediaOwner | undefined
}) {
  const { model, ctx, owner } = props
  const voice = props.raw.kind === "voice" ? props.raw.voice : undefined
  const source = voice ? ctx.env.sources.voice(voice, owner) : pendingSource
  const holdRef = useElement(holdPart(source))
  const state = useSignal(source.state)
  const url = state.status === "ready" ? state.url : undefined
  const player = useModel(
    () => new VoicePlayerController({ url, duration: model.duration, group: ctx.env.playback }),
    [url],
  )
  const audioRef = useElement<HTMLAudioElement>(player.part)
  const status = useSignal(player.status)
  const position = useSignal(player.position)
  const duration = useSignal(player.duration)
  const playing = status === "playing" || status === "loading"
  const progress = duration > 0 ? Math.min(1, position / duration) : 0
  const outgoing = ctx.tone === "outgoing"
  const failed = status === "failed" || state.status === "failed"
  const time = playing || position > 0 ? formatDuration(position) : model.durationText

  const seekFromPointer = (event: PointerEvent<HTMLElement>) => {
    const rect = event.currentTarget.getBoundingClientRect()
    if (rect.width <= 0) return
    const rtl = getComputedStyle(event.currentTarget).direction === "rtl"
    const fraction = rtl ? (rect.right - event.clientX) / rect.width : (event.clientX - rect.left) / rect.width
    player.seek(fraction)
  }
  const seekFromKey = (event: KeyboardEvent<HTMLElement>) => {
    const rtl = getComputedStyle(event.currentTarget).direction === "rtl"
    const step = event.key === "ArrowRight" ? (rtl ? -0.05 : 0.05) : event.key === "ArrowLeft" ? (rtl ? 0.05 : -0.05) : 0
    if (event.key === "Home") player.seek(0)
    else if (event.key === "End") player.seek(1)
    else if (step !== 0) player.seek(progress + step)
    else return
    event.preventDefault()
  }

  return (
    <div
      ref={holdRef}
      data-media-box={model.key}
      data-media-kind="voice"
      {...stylex.props(styles.voiceRow, dynamic.fixed(model.width, model.height))}
    >
      <button
        type="button"
        aria-label={failed ? "Couldn’t play. Try again" : playing ? "Pause voice message" : "Play voice message"}
        disabled={!player.canPlay && !failed}
        onClick={
          failed
            ? () => {
                source.retry()
                player.play()
              }
            : () => player.toggle()
        }
        {...stylex.props(styles.voiceButton, outgoing && styles.voiceButtonOutgoing)}
      >
        {failed ? <RetryIcon /> : playing ? <PauseIcon size={14} /> : <PlayIcon size={14} />}
      </button>
      <span
        role="slider"
        tabIndex={player.canPlay ? 0 : -1}
        aria-label="Playback position"
        aria-valuemin={0}
        aria-valuemax={Math.round(duration)}
        aria-valuenow={Math.round(position)}
        aria-valuetext={`${formatDuration(position)} of ${formatDuration(duration)}`}
        onPointerDown={player.canPlay ? seekFromPointer : undefined}
        onKeyDown={player.canPlay ? seekFromKey : undefined}
        {...stylex.props(styles.waveform)}
      >
        <Waveform bars={model.bars} progress={progress} outgoing={outgoing} />
      </span>
      <span {...stylex.props(styles.voiceTime, outgoing ? styles.onAccentSecondary : styles.secondary)}>{time}</span>
      <audio ref={audioRef} preload="none" />
    </div>
  )
})

/** 48 bars as SVG rectangles: no per-bar styles, the played part in the accent. */
function Waveform(props: { bars: readonly number[]; progress: number; outgoing: boolean }) {
  const count = props.bars.length
  const played = Math.round(props.progress * count)
  const width = count * 3
  return (
    <svg
      viewBox={`0 0 ${width} 24`}
      preserveAspectRatio="none"
      aria-hidden="true"
      focusable="false"
      {...stylex.props(styles.waveSvg)}
    >
      {props.bars.map((bar, index) => {
        const height = Math.max(2, bar * 24)
        return (
          <rect
            key={index}
            x={index * 3}
            y={(24 - height) / 2}
            width={2}
            height={height}
            rx={1}
            {...stylex.props(
              props.outgoing
                ? index < played
                  ? styles.barOutgoingPlayed
                  : styles.barOutgoing
                : index < played
                  ? styles.barPlayed
                  : styles.bar,
            )}
          />
        )
      })}
    </svg>
  )
}

// ---------------------------------------------------------------------------

/** Wraps media so the row's content slot keeps a consistent gap. */
export function MediaFrame(props: { children: ReactNode }) {
  return <div {...stylex.props(styles.frame)}>{props.children}</div>
}

const styles = stylex.create({
  frame: { display: "flex", flexDirection: "column", gap: space.xs, minInlineSize: 0 },
  box: {
    position: "relative",
    display: "block",
    flexShrink: 0,
    maxInlineSize: "100%",
    overflow: "hidden",
    boxSizing: "border-box",
    isolation: "isolate",
  },
  rounded: { borderRadius: MEDIA_RADIUS },
  roundedSmall: { borderRadius: radius.small },
  surface: { backgroundColor: `color-mix(in srgb, ${color.label} 8%, transparent)` },
  layer: { position: "absolute", inset: 0, inlineSize: "100%", blockSize: "100%" },
  preview: {
    backgroundSize: "cover",
    backgroundPosition: "center",
    filter: "blur(12px)",
    transform: "scale(1.12)",
  },
  cover: { position: "absolute", inset: 0, inlineSize: "100%", blockSize: "100%", objectFit: "cover" },
  contain: { objectFit: "contain" },
  image: {
    opacity: 0,
    transitionProperty: "opacity",
    transitionDuration: motion.durationSlow,
    transitionTimingFunction: motion.easeOut,
  },
  shown: { opacity: 1 },
  instant: { transitionDuration: "0ms" },
  hit: {
    display: "block",
    margin: 0,
    padding: 0,
    borderStyle: "none",
    backgroundColor: "transparent",
    color: "inherit",
    cursor: { default: "zoom-in", ":disabled": "default" },
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "-2px",
    borderRadius: "inherit",
  },
  retry: {
    position: "absolute",
    insetBlockStart: "50%",
    insetInlineStart: "50%",
    transform: "translate(-50%, -50%)",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: "32px",
    blockSize: "32px",
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: `color-mix(in srgb, ${color.windowBackground} 80%, transparent)`,
    color: color.label,
    cursor: "pointer",
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
  },
  play: {
    position: "absolute",
    insetBlockStart: "50%",
    insetInlineStart: "50%",
    transform: "translate(-50%, -50%)",
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: "40px",
    blockSize: "40px",
    paddingInlineStart: "2px",
    boxSizing: "border-box",
    borderRadius: radius.pill,
    backgroundColor: "rgb(0 0 0 / 0.45)",
    color: color.onAccent,
    pointerEvents: "none",
  },
  badge: {
    position: "absolute",
    insetBlockStart: space.sm,
    insetInlineStart: space.sm,
    paddingInline: space.sm,
    paddingBlock: "1px",
    borderRadius: radius.pill,
    backgroundColor: "rgb(0 0 0 / 0.5)",
    color: color.onAccent,
    fontSize: font.sizeFootnote,
    fontWeight: font.weightMedium,
    lineHeight: "14px",
    fontVariantNumeric: "tabular-nums",
    pointerEvents: "none",
  },
  unavailable: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    color: color.secondaryLabel,
  },
  albumScroller: {
    maxInlineSize: "100%",
    overflowX: "auto",
    overflowY: "hidden",
    scrollbarWidth: "thin",
    overscrollBehaviorX: "contain",
  },
  albumStrip: { display: "flex", gap: "6px" },
  documentRow: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    maxInlineSize: "100%",
    boxSizing: "border-box",
  },
  documentThumbnail: { inlineSize: "70px", blockSize: "70px", borderRadius: "8px" },
  fileIcon: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    inlineSize: "36px",
    blockSize: "36px",
    borderRadius: radius.pill,
    backgroundColor: color.accent,
    color: color.onAccent,
  },
  fileIconOutgoing: { backgroundColor: color.onAccent, color: color.accent },
  documentText: { display: "flex", flexDirection: "column", flexGrow: 1, minInlineSize: 0, gap: "1px" },
  fileName: {
    display: "flex",
    minInlineSize: 0,
    fontSize: font.sizeBody,
    fontWeight: font.weightMedium,
    lineHeight: "16px",
    whiteSpace: "nowrap",
  },
  fileHead: { overflow: "hidden", textOverflow: "ellipsis", minInlineSize: 0 },
  fileTail: { flexShrink: 0 },
  fileMeta: { fontSize: font.sizeCallout, lineHeight: "15px", fontVariantNumeric: "tabular-nums" },
  secondary: { color: color.secondaryLabel },
  onAccentSecondary: { color: `color-mix(in srgb, ${color.onAccent} 75%, transparent)` },
  onAccentControl: { color: color.onAccent },
  voiceRow: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    maxInlineSize: "100%",
    boxSizing: "border-box",
  },
  voiceButton: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    inlineSize: "32px",
    blockSize: "32px",
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: color.accent,
    color: color.onAccent,
    cursor: { default: "pointer", ":disabled": "default" },
    opacity: { default: 1, ":disabled": 0.5 },
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "2px",
  },
  voiceButtonOutgoing: { backgroundColor: color.onAccent, color: color.accent },
  waveform: {
    display: "block",
    flexGrow: 1,
    minInlineSize: 0,
    blockSize: "24px",
    cursor: "pointer",
    borderRadius: radius.small,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    touchAction: "none",
  },
  waveSvg: { display: "block", inlineSize: "100%", blockSize: "100%", transform: { default: null, ":dir(rtl)": "scaleX(-1)" } },
  bar: { fill: `color-mix(in srgb, ${color.label} 30%, transparent)` },
  barPlayed: { fill: color.accent },
  barOutgoing: { fill: `color-mix(in srgb, ${color.onAccent} 45%, transparent)` },
  barOutgoingPlayed: { fill: color.onAccent },
  voiceTime: { flexShrink: 0, fontSize: font.sizeCallout, fontVariantNumeric: "tabular-nums", minInlineSize: "32px" },
})

const dynamic = stylex.create({
  /** Width from the model; height follows the aspect ratio, so a narrower column scales the box. */
  box: (width: number, height: number) => ({ inlineSize: `${width}px`, aspectRatio: `${width} / ${height}` }),
  fixed: (width: number, height: number) => ({ inlineSize: `${width}px`, blockSize: `${height}px` }),
  documentHeight: (height: number, minWidth: number) => ({ blockSize: `${height}px`, minInlineSize: `${minWidth}px` }),
})
