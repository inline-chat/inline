import { useCallback, useEffect, useLayoutEffect, useRef } from "react"
import { chatOpenPerformance } from "./ChatOpenPerformance"

/** Completes the browser half of a ChatOpenPerformance trace. Two animation
 * frames ensure at least one rendering opportunity occurred after the list's
 * layout effect, rather than mislabeling a React commit as a paint. */
export function useChatOpenPaintTrace(
  performanceTraceId: string | undefined,
  renderedMessageCount: number,
) {
  const pendingPaint = useRef<{
    traceId: string
    frames: number[]
  } | undefined>(undefined)

  const cancelPendingPaint = useCallback(() => {
    const pending = pendingPaint.current
    if (!pending) return
    for (const frame of pending.frames) cancelAnimationFrame(frame)
    pendingPaint.current = undefined
  }, [])

  const onFirstLayout = useCallback(() => {
    if (!performanceTraceId) return
    cancelPendingPaint()
    chatOpenPerformance.markFirstLayout(
      performanceTraceId,
      renderedMessageCount,
    )
    const pending = {
      traceId: performanceTraceId,
      frames: [] as number[],
    }
    pendingPaint.current = pending
    const afterFirstFrame = requestAnimationFrame(() => {
      const afterPaint = requestAnimationFrame(() => {
        chatOpenPerformance.markFirstPaint(performanceTraceId)
        if (pendingPaint.current === pending) {
          pendingPaint.current = undefined
        }
      })
      pending.frames.push(afterPaint)
    })
    pending.frames.push(afterFirstFrame)
  }, [cancelPendingPaint, performanceTraceId, renderedMessageCount])

  useLayoutEffect(() => {
    if (
      pendingPaint.current &&
      pendingPaint.current.traceId !== performanceTraceId
    ) {
      cancelPendingPaint()
    }
  }, [cancelPendingPaint, performanceTraceId])

  useEffect(
    () => cancelPendingPaint,
    [cancelPendingPaint],
  )

  return onFirstLayout
}
