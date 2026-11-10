import {
  normalizeMessagePresentation,
  renderMessagePresentationFallbackText,
  type MessagePresentation,
} from "openclaw/plugin-sdk/interactive-runtime"

/**
 * Normalize an untyped legacy `interactive` value as a MessagePresentation.
 *
 * Some OpenClaw producers (plugin command results, older message-tool calls)
 * still emit `{ blocks: [text | buttons | select] }` under `interactive`. That
 * shape is a structural subset of MessagePresentation, so it normalizes through
 * the presentation contract directly. Only the legacy block kinds are kept so
 * the result matches what those producers could express.
 */
export function normalizeInlineLegacyInteractivePresentation(
  raw: unknown,
): MessagePresentation | undefined {
  const presentation = normalizeMessagePresentation(raw)
  if (!presentation) {
    return undefined
  }
  const blocks = presentation.blocks.filter(
    (block) => block.type === "text" || block.type === "buttons" || block.type === "select",
  )
  return blocks.length > 0 ? { blocks } : undefined
}

export function resolveInlineInteractiveTextFallback(params: {
  text?: string | null | undefined
  interactive?: unknown | undefined
  presentation?: unknown | undefined
  presentationTextMode?: "fallback" | undefined
}): string | undefined {
  const text = params.text ?? undefined
  const presentation = normalizeMessagePresentation(params.presentation)
  if (presentation) {
    if (params.presentationTextMode === "fallback" && text?.trim()) return text
    const fallback = renderMessagePresentationFallbackText({ ...(text !== undefined ? { text } : {}), presentation })
    if (fallback.trim()) return fallback
  }
  if (text?.trim()) {
    return text
  }

  const legacy = normalizeInlineLegacyInteractivePresentation(params.interactive)
  const legacyText = (legacy?.blocks ?? [])
    .flatMap((block) => (block.type === "text" ? [block.text.trim()] : []))
    .filter(Boolean)
    .join("\n\n")
  if (legacyText) {
    return legacyText
  }

  if (!legacy) {
    return text
  }

  const fallback = renderMessagePresentationFallbackText({ presentation: legacy })
  return fallback.trim() ? fallback : text
}
