import {
  interactiveReplyToPresentation,
  normalizeInteractiveReply,
  normalizeMessagePresentation,
  renderMessagePresentationFallbackText,
  resolveInteractiveTextFallback,
} from "openclaw/plugin-sdk/interactive-runtime"

export function resolveInlineInteractiveTextFallback(params: {
  text?: string | null | undefined
  interactive?: unknown | undefined
  presentation?: unknown | undefined
}): string | undefined {
  const interactive = normalizeInteractiveReply(params.interactive)
  const text = resolveInteractiveTextFallback({
    ...(params.text != null ? { text: params.text } : {}),
    ...(interactive ? { interactive } : {}),
  })
  if (text?.trim()) {
    return text
  }

  const presentation = normalizeMessagePresentation(params.presentation)
  if (presentation) {
    const fallback = renderMessagePresentationFallbackText({
      ...(params.text != null ? { text: params.text } : {}),
      presentation,
    })
    if (fallback.trim()) {
      return fallback
    }
  }

  if (!interactive) {
    return text
  }

  const interactivePresentation = interactiveReplyToPresentation(interactive)
  if (!interactivePresentation) {
    return text
  }

  const fallback = renderMessagePresentationFallbackText({ presentation: interactivePresentation })
  return fallback.trim() ? fallback : text
}
