const resizeObserverLoopMessages = new Set([
  "ResizeObserver loop completed with undelivered notifications.",
  "ResizeObserver loop limit exceeded",
])

export const isResizeObserverLoopError = (message: string) =>
  resizeObserverLoopMessages.has(message)

/**
 * Chromium reports ResizeObserver's spec-mandated deferred-delivery warning as
 * a global error. Virtua documents this exact notification as benign. Keep it
 * out of the app error boundary without suppressing any other runtime error.
 */
export const resizeObserverErrorSuppressionScript = `
window.addEventListener("error", function (event) {
  if (
    event.message !== "ResizeObserver loop completed with undelivered notifications." &&
    event.message !== "ResizeObserver loop limit exceeded"
  ) return
  event.preventDefault()
  event.stopImmediatePropagation()
}, true)
`
