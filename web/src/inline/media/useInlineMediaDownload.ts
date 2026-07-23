import { useCallback, useEffect, useRef, useState } from "react"
import {
  downloadInlineMedia,
  type InlineMediaDownloadProgress,
} from "./InlineMediaDownload"

export type InlineMediaDownloadState =
  | { status: "idle" }
  | { status: "downloading"; progress?: InlineMediaDownloadProgress }
  | { status: "saved" }
  | { status: "failed"; message: string }

export const useInlineMediaDownload = (url: string | undefined, fileName: string) => {
  const [state, setState] = useState<InlineMediaDownloadState>({ status: "idle" })
  const controller = useRef<AbortController | undefined>(undefined)
  const progressFrame = useRef<number | undefined>(undefined)
  const pendingProgress = useRef<InlineMediaDownloadProgress | undefined>(undefined)

  const flushProgress = useCallback(() => {
    progressFrame.current = undefined
    const progress = pendingProgress.current
    if (progress) setState({ status: "downloading", progress })
  }, [])

  const cancel = useCallback(() => {
    controller.current?.abort()
    controller.current = undefined
    if (progressFrame.current != null) cancelAnimationFrame(progressFrame.current)
    progressFrame.current = undefined
    pendingProgress.current = undefined
    setState({ status: "idle" })
  }, [])

  const start = useCallback(async () => {
    if (!url || controller.current) return
    const nextController = new AbortController()
    controller.current = nextController
    setState({ status: "downloading" })
    try {
      await downloadInlineMedia(url, fileName, {
        signal: nextController.signal,
        onProgress: (progress) => {
          pendingProgress.current = progress
          progressFrame.current ??= requestAnimationFrame(flushProgress)
        },
      })
      if (!nextController.signal.aborted) setState({ status: "saved" })
    } catch (cause) {
      if (
        nextController.signal.aborted ||
        (cause instanceof DOMException && cause.name === "AbortError")
      ) {
        setState({ status: "idle" })
      } else {
        setState({
          status: "failed",
          message: cause instanceof Error ? cause.message : "Download failed.",
        })
      }
    } finally {
      if (controller.current === nextController) controller.current = undefined
      if (progressFrame.current != null) cancelAnimationFrame(progressFrame.current)
      progressFrame.current = undefined
      pendingProgress.current = undefined
    }
  }, [fileName, flushProgress, url])

  useEffect(
    () => () => {
      controller.current?.abort()
      if (progressFrame.current != null) {
        cancelAnimationFrame(progressFrame.current)
      }
    },
    [],
  )
  return { state, start, cancel }
}
