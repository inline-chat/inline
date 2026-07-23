import * as stylex from "@stylexjs/stylex"
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react"
import { createPortal } from "react-dom"
import { useInlineMediaDownload } from "../inline/media/useInlineMediaDownload"
import { Icon } from "~/ui/Icon"
import type { ChatMessageMediaPresentation } from "./MessageContent"
import {
  containedInlineMediaRect,
  type InlineMediaViewerRect,
} from "./InlineMediaViewerGeometry"

type ViewerMedia = Extract<
  ChatMessageMediaPresentation,
  { kind: "photo" | "video" }
>

const rectFromElement = (element: HTMLElement): InlineMediaViewerRect => {
  const rect = element.getBoundingClientRect()
  return {
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  }
}

const frame = (rect: InlineMediaViewerRect, radius: number) => ({
  left: `${rect.left}px`,
  top: `${rect.top}px`,
  width: `${rect.width}px`,
  height: `${rect.height}px`,
  borderRadius: `${radius}px`,
})

const viewerDuration = 170

export function InlineMediaViewer({
  media,
  url,
  downloadUrl,
  posterUrl,
  source,
  onClose,
}: {
  media: ViewerMedia
  url: string
  downloadUrl?: string
  posterUrl?: string
  source: HTMLElement
  onClose: () => void
}) {
  const mediaElement = useRef<HTMLImageElement | HTMLVideoElement>(null)
  const overlay = useRef<HTMLDivElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)
  const closing = useRef(false)
  const sourceRect = useRef(rectFromElement(source))
  const [settledRect, setSettledRect] = useState(sourceRect.current)
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches
  const targetRect = useCallback(
    () =>
      containedInlineMediaRect(
        media.width,
        media.height,
        window.innerWidth,
        window.innerHeight,
      ),
    [media.height, media.width],
  )
  const downloadName = media.kind === "photo" ? "Inline photo.jpg" : "Inline video.mp4"
  const download = useInlineMediaDownload(downloadUrl, downloadName)

  useLayoutEffect(() => {
    const element = mediaElement.current
    const target = targetRect()
    if (!element || reducedMotion) {
      setSettledRect(target)
      return
    }
    const animation = element.animate(
      [frame(sourceRect.current, 10), frame(target, 4)],
      {
        duration: viewerDuration,
        easing: "cubic-bezier(.2,.8,.2,1)",
      },
    )
    const backdropAnimation = overlay.current?.animate(
      [
        { backgroundColor: "rgba(0,0,0,0)" },
        { backgroundColor: "rgba(0,0,0,.82)" },
      ],
      { duration: viewerDuration, easing: "ease-out" },
    )
    void animation.finished
      .then(() => setSettledRect(target))
      .catch(() => undefined)
    return () => {
      animation.cancel()
      backdropAnimation?.cancel()
    }
  }, [reducedMotion, targetRect])

  useEffect(() => {
    const previousOverflow = document.body.style.overflow
    const previousFocus = document.activeElement as HTMLElement | null
    const siblings = Array.from(document.body.children).filter(
      (element): element is HTMLElement =>
        element instanceof HTMLElement && element !== overlay.current,
    )
    const previousInert = siblings.map((element) => element.inert)
    for (const sibling of siblings) sibling.inert = true
    document.body.style.overflow = "hidden"
    closeButton.current?.focus()
    return () => {
      document.body.style.overflow = previousOverflow
      siblings.forEach((sibling, index) => {
        sibling.inert = previousInert[index] ?? false
      })
      if (previousFocus?.isConnected) previousFocus.focus()
    }
  }, [])

  const close = useCallback(async () => {
    if (closing.current) return
    closing.current = true
    const element = mediaElement.current
    const destination = source.isConnected
      ? rectFromElement(source)
      : sourceRect.current
    if (element && !reducedMotion) {
      const current = rectFromElement(element)
      const mediaAnimation = element.animate(
        [frame(current, 4), frame(destination, 10)],
        {
          duration: viewerDuration,
          easing: "cubic-bezier(.4,0,.2,1)",
          fill: "forwards",
        },
      )
      const overlayAnimation = overlay.current?.animate(
        [{ backgroundColor: "rgba(0,0,0,.82)" }, { backgroundColor: "rgba(0,0,0,0)" }],
        { duration: viewerDuration, fill: "forwards" },
      )
      await Promise.allSettled([
        mediaAnimation.finished,
        overlayAnimation?.finished,
      ])
    }
    onClose()
  }, [onClose, reducedMotion, source])

  useEffect(() => {
    const keyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault()
        void close()
        return
      }
      if (event.key === "Tab") {
        const actions = overlay.current?.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])',
        )
        if (!actions?.length) return
        const first = actions[0]!
        const last = actions[actions.length - 1]!
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault()
          last.focus()
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault()
          first.focus()
        }
        return
      }
      if (
        event.key === " " &&
        media.kind === "video" &&
        !(event.target instanceof HTMLButtonElement)
      ) {
        const video = mediaElement.current as HTMLVideoElement | null
        if (!video) return
        event.preventDefault()
        if (video.paused) void video.play()
        else video.pause()
      }
    }
    window.addEventListener("keydown", keyDown)
    return () => window.removeEventListener("keydown", keyDown)
  }, [close, media.kind])

  useEffect(() => {
    const resize = () => setSettledRect(targetRect())
    window.addEventListener("resize", resize)
    return () => window.removeEventListener("resize", resize)
  }, [targetRect])

  return createPortal(
    <div
      ref={overlay}
      role="dialog"
      aria-modal="true"
      aria-label={`${media.label} viewer`}
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) void close()
      }}
      {...stylex.props(styles.overlay)}
    >
      <span {...stylex.props(styles.actions)}>
        <button
          type="button"
          aria-label={download.state.status === "downloading" ? "Cancel media download" : "Download media"}
          aria-busy={download.state.status === "downloading" || undefined}
          disabled={!downloadUrl}
          title={
            download.state.status === "downloading"
              ? "Cancel Download"
              : downloadUrl
                ? "Download"
                : "Download available when media finishes loading"
          }
          onClick={() => {
            if (download.state.status === "downloading") download.cancel()
            else void download.start()
          }}
          {...stylex.props(styles.action)}
        >
          {download.state.status === "downloading" ? "×" : "↓"}
        </button>
        <button
          ref={closeButton}
          type="button"
          aria-label="Close media viewer"
          title="Close"
          onClick={() => void close()}
          {...stylex.props(styles.action)}
        >
          <Icon name="xmark" size={17} />
        </button>
      </span>
      {download.state.status === "failed" ? (
        <span role="alert" {...stylex.props(styles.downloadError)}>
          Download failed. Try again.
        </span>
      ) : null}
      {media.kind === "photo" ? (
        <img
          ref={mediaElement as React.RefObject<HTMLImageElement>}
          src={url}
          alt="Photo"
          draggable={false}
          style={frame(settledRect, 4)}
          {...stylex.props(styles.media)}
        />
      ) : (
        <video
          ref={mediaElement as React.RefObject<HTMLVideoElement>}
          src={url}
          poster={posterUrl}
          autoPlay
          controls={!media.animated}
          loop={media.animated}
          muted={media.animated}
          playsInline
          style={frame(settledRect, 4)}
          {...stylex.props(styles.media)}
        />
      )}
    </div>,
    document.body,
  )
}

const styles = stylex.create({
  overlay: {
    position: "fixed",
    inset: 0,
    zIndex: 900,
    backgroundColor: "rgba(0,0,0,.82)",
  },
  actions: {
    position: "fixed",
    top: 16,
    right: 16,
    zIndex: 902,
    display: "flex",
    gap: 6,
  },
  action: {
    width: 34,
    height: 34,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderRadius: "50%",
    backgroundColor: {
      default: "rgba(24,24,24,.78)",
      ":hover": "rgba(48,48,48,.88)",
    },
    color: "#fff",
    fontSize: 18,
    cursor: {
      default: "pointer",
      ":disabled": "default",
    },
    opacity: {
      default: 1,
      ":disabled": 0.42,
    },
  },
  media: {
    position: "fixed",
    zIndex: 901,
    display: "block",
    objectFit: "contain",
    outline: "none",
    userSelect: "none",
  },
  downloadError: {
    position: "fixed",
    zIndex: 902,
    top: 21,
    right: 100,
    paddingBlock: 6,
    paddingInline: 9,
    borderRadius: 7,
    backgroundColor: "rgba(24,24,24,.78)",
    color: "#fff",
    fontSize: 11,
  },
})
