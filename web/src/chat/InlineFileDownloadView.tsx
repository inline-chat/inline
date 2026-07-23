import * as stylex from "@stylexjs/stylex"
import { useInlineMediaDownload } from "~/inline/media/useInlineMediaDownload"
import { colors } from "../styles/tokens.stylex"
import type { ChatMessageMediaPresentation } from "./MessageContent"

type DocumentPresentation = Extract<
  ChatMessageMediaPresentation,
  { kind: "document" }
>

const fileSize = (value?: number) => {
  if (!value) return undefined
  if (value < 1_000_000) return `${Math.max(1, Math.round(value / 1_000))} KB`
  return `${(value / 1_000_000).toFixed(value < 10_000_000 ? 1 : 0)} MB`
}

const progressLabel = (
  state: ReturnType<typeof useInlineMediaDownload>["state"],
  size?: number,
) => {
  if (state.status === "downloading") {
    const progress = state.progress
    if (progress?.totalBytes) {
      return `${Math.min(100, Math.round((progress.receivedBytes / progress.totalBytes) * 100))}% · Cancel`
    }
    return "Downloading… · Cancel"
  }
  if (state.status === "failed") return "Download failed · Retry"
  if (state.status === "saved") return "Downloaded · Download again"
  return fileSize(size) ?? "Download"
}

export function InlineFileDownloadView({ media }: { media: DocumentPresentation }) {
  const download = useInlineMediaDownload(media.remoteUrl, media.fileName)
  const downloading = download.state.status === "downloading"
  return (
    <button
      type="button"
      disabled={!media.remoteUrl}
      aria-busy={downloading || undefined}
      onClick={() => {
        if (downloading) download.cancel()
        else void download.start()
      }}
      {...stylex.props(styles.file)}
    >
      <span aria-hidden="true" {...stylex.props(styles.fileIcon)}>
        {downloading ? "×" : "↓"}
      </span>
      <span {...stylex.props(styles.fileText)}>
        <span {...stylex.props(styles.fileName)}>{media.fileName}</span>
        <span
          role={download.state.status === "failed" ? "alert" : undefined}
          title={download.state.status === "failed" ? download.state.message : undefined}
          {...stylex.props(
            styles.detail,
            download.state.status === "failed" && styles.failed,
          )}
        >
          {progressLabel(download.state, media.size)}
        </span>
      </span>
    </button>
  )
}

const styles = stylex.create({
  file: {
    minWidth: 180,
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingBlock: 2,
    paddingInline: 0,
    backgroundColor: "transparent",
    color: "inherit",
    textAlign: "left",
    cursor: "pointer",
    ":disabled": {
      cursor: "default",
      opacity: 0.55,
    },
  },
  fileIcon: {
    width: 30,
    height: 30,
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    borderRadius: 8,
    backgroundColor: "rgba(127,127,127,.16)",
    fontSize: 15,
  },
  fileText: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 1,
  },
  fileName: {
    maxWidth: 220,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  detail: {
    opacity: 0.62,
    fontSize: 9,
    whiteSpace: "nowrap",
  },
  failed: {
    color: colors.destructive,
    opacity: 1,
  },
})
