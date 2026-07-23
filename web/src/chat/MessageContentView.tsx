import * as stylex from "@stylexjs/stylex"
import {
  useInlineMediaUrl,
  useInlineStreamingMediaUrl,
} from "../inline/media/InlineMediaContext"
import { colors } from "../styles/tokens.stylex"
import type {
  ChatMessageMediaPresentation,
  ChatMessagePresentation,
} from "./MessageContent"
import { messageMediaDisplaySize } from "./MessageContent"
import { MessageAttachmentsView } from "./MessageAttachmentsView"
import { InlineMessageTextView } from "./InlineMessageTextView"
import { useRef, useState } from "react"
import { InlineMediaViewer } from "./InlineMediaViewer"
import { InlineFileDownloadView } from "./InlineFileDownloadView"

const formatDuration = (seconds?: number) => {
  if (!seconds) return undefined
  const minutes = Math.floor(seconds / 60)
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`
}

function MediaFrame({
  media,
  hasCaption,
}: {
  media: Extract<ChatMessageMediaPresentation, { kind: "photo" | "video" }>
  hasCaption: boolean
}) {
  const source = useRef<HTMLButtonElement>(null)
  const [viewerOpen, setViewerOpen] = useState(false)
  const dimensions = messageMediaDisplaySize(
    media.width,
    media.height,
    hasCaption,
  )
  const cachedOrPhotoUrl = useInlineMediaUrl(
    media.kind === "photo" ? media.mediaKey : undefined,
    media.kind === "photo" ? media.remoteUrl : undefined,
  )
  const streamingVideoUrl = useInlineStreamingMediaUrl(
    media.kind === "video" ? media.mediaKey : undefined,
    media.kind === "video" ? media.remoteUrl : undefined,
  )
  const url = media.kind === "video"
    ? streamingVideoUrl
    : cachedOrPhotoUrl
  const posterUrl = useInlineMediaUrl(
    media.kind === "video" ? media.posterKey : undefined,
    media.kind === "video" ? media.posterUrl : undefined,
  )
  const style = {
    width: dimensions.width,
    height: dimensions.height,
    aspectRatio: `${media.width} / ${media.height}`,
  }

  return (
    <>
    <button
      ref={source}
      type="button"
      aria-label={`Open ${media.label.toLowerCase()}`}
      disabled={!url && !media.tinyThumbnailUrl}
      onClick={() => setViewerOpen(true)}
      style={style}
      {...stylex.props(styles.mediaFrame)}
    >
      {media.tinyThumbnailUrl ? (
        <img
          src={media.tinyThumbnailUrl}
          alt=""
          aria-hidden="true"
          {...stylex.props(styles.tinyThumbnail)}
        />
      ) : null}
      {!media.tinyThumbnailUrl ? (
        <span {...stylex.props(styles.mediaPlaceholder)}>{media.label}</span>
      ) : null}
      {url && media.kind === "video" ? (
      <video
        src={url}
        poster={posterUrl}
        width={media.width}
        height={media.height}
        preload="metadata"
        controls={false}
        autoPlay={media.animated}
        loop={media.animated}
        muted={media.animated}
        playsInline
        aria-label={media.label}
        {...stylex.props(styles.fullMedia)}
      />
      ) : null}
      {url && media.kind === "photo" ? (
        <img
          src={url}
          alt="Photo"
          width={media.width}
          height={media.height}
          loading="eager"
          decoding="async"
          {...stylex.props(styles.fullMedia)}
        />
      ) : null}
    </button>
    {viewerOpen && source.current && (url || media.tinyThumbnailUrl) ? (
      <InlineMediaViewer
        media={media}
        url={url ?? media.tinyThumbnailUrl!}
        downloadUrl={url}
        posterUrl={posterUrl}
        source={source.current}
        onClose={() => setViewerOpen(false)}
      />
    ) : null}
    </>
  )
}

function MessageMediaContent({
  media,
  hasCaption,
}: {
  media: ChatMessageMediaPresentation
  hasCaption: boolean
}) {
  switch (media.kind) {
    case "photo":
    case "video":
      return <MediaFrame media={media} hasCaption={hasCaption} />
    case "document":
      return <InlineFileDownloadView media={media} />
    case "voice":
      return (
        <span aria-label={media.label} {...stylex.props(styles.voice)}>
          <span {...stylex.props(styles.waveform)}>
            {Array.from({ length: 18 }, (_, index) => (
              <i
                key={index}
                style={{
                  height: Math.max(3, media.waveform[index] ?? ((index * 7) % 13) + 3),
                }}
                {...stylex.props(styles.waveformBar)}
              />
            ))}
          </span>
          <span {...stylex.props(styles.voiceLabel)}>
            <span>{media.label}</span>
            {media.duration ? (
              <span {...stylex.props(styles.detail)}>{formatDuration(media.duration)}</span>
            ) : null}
          </span>
        </span>
      )
    case "nudge":
      return <span {...stylex.props(styles.nudge)}>👋 Nudge</span>
  }
}

export function MessageContentView({
  presentation,
}: {
  presentation: ChatMessagePresentation
}) {
  const hasText = Boolean(presentation.text)
  return (
    <span {...stylex.props(styles.root)}>
      {presentation.media ? (
        <MessageMediaContent media={presentation.media} hasCaption={hasText} />
      ) : null}
      {presentation.text ? (
        <InlineMessageTextView
          text={presentation.text}
          entities={presentation.entities}
          {...stylex.props(styles.text)}
        />
      ) : null}
      {presentation.fallback ? (
        <span {...stylex.props(styles.text, styles.contentFallback)}>
          {presentation.fallback}
        </span>
      ) : null}
      {presentation.attachments?.length ? (
        <MessageAttachmentsView attachments={presentation.attachments} />
      ) : null}
    </span>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 5,
  },
  text: {
    minWidth: 0,
    overflowWrap: "anywhere",
    whiteSpace: "pre-wrap",
  },
  contentFallback: {
    color: colors.textSecondary,
  },
  mediaFrame: {
    maxWidth: "min(320px, calc(100vw - 104px))",
    position: "relative",
    display: "block",
    overflow: "hidden",
    borderRadius: 10,
    backgroundColor: "light-dark(rgba(0,0,0,.06), rgba(255,255,255,.08))",
    padding: 0,
    color: "inherit",
    textAlign: "inherit",
    cursor: "zoom-in",
  },
  mediaPlaceholder: {
    position: "absolute",
    inset: 0,
    display: "grid",
    placeItems: "center",
    color: colors.textSecondary,
    fontSize: 11,
  },
  tinyThumbnail: {
    position: "absolute",
    inset: 0,
    width: "100%",
    height: "100%",
    objectFit: "cover",
    filter: "blur(7px) saturate(1.25)",
    transform: "scale(1.12)",
  },
  fullMedia: {
    position: "absolute",
    inset: 0,
    width: "100%",
    height: "100%",
    objectFit: "cover",
  },
  detail: {
    opacity: 0.62,
    fontSize: 9,
    whiteSpace: "nowrap",
  },
  voice: {
    width: 220,
    maxWidth: "calc(100vw - 124px)",
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingBlock: 2,
  },
  voiceLabel: {
    display: "flex",
    flexDirection: "column",
    gap: 1,
    fontSize: 11,
  },
  waveform: {
    height: 20,
    display: "flex",
    alignItems: "center",
    flex: 1,
    gap: 2,
    overflow: "hidden",
  },
  waveformBar: {
    width: 2,
    maxHeight: 18,
    display: "block",
    flexShrink: 0,
    borderRadius: 1,
    backgroundColor: "currentColor",
    opacity: 0.4,
  },
  nudge: {
    fontWeight: 500,
  },
})
