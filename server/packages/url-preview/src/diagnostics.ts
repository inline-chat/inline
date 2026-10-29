import { UrlPreviewError } from "./errors.js"
import type { PreviewDiagnostic } from "./types.js"

const errorCodes = new Set([
  "blocked_host", "blocked_ip", "invalid_url", "sensitive_query", "sensitive_path",
  "dns_failed", "timeout", "capacity", "too_many_redirects", "response_too_large",
  "http_status", "unsupported_content_type", "unsupported_encoding", "invalid_response",
])

export function previewErrorDiagnostic(error: unknown): Pick<PreviewDiagnostic, "code" | "status"> {
  if (error instanceof UrlPreviewError) {
    return { code: errorCodes.has(error.code) ? error.code : "fetch_failed", status: error.status }
  }
  return { code: error instanceof Error && error.name === "AbortError" ? "timeout" : "fetch_failed" }
}

export function reportPreviewDiagnostic(
  options: { onDiagnostic?: (diagnostic: PreviewDiagnostic) => void },
  diagnostic: PreviewDiagnostic,
): void {
  try {
    options.onDiagnostic?.(diagnostic)
  } catch {
    // Diagnostics must never prevent a preview or its fallback from loading.
  }
}
