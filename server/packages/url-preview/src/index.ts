import { fetchGenericPreview } from "./providers/generic.js"
import { previewProviders } from "./providers/index.js"
import { normalizePreviewUrl } from "./normalize.js"
import type { FetchUrlPreviewOptions, UrlPreviewResult } from "./types.js"
import { previewErrorDiagnostic, reportPreviewDiagnostic } from "./diagnostics.js"

export { UrlPreviewError } from "./errors.js"
export {
  authenticatedPreviewProviders,
  fetchAuthenticatedUrlPreview,
  parseAuthenticatedPreviewUrl,
} from "./auth/index.js"
export { extractPreviewUrl, extractPreviewUrls } from "./extract.js"
export { filterPreviewUrl, isBlockedHostname, isBlockedIp } from "./filters.js"
export { fetchBinary } from "./network.js"
export { isPreviewAuthorImageUrl } from "./imageRoles.js"
export { previewLayout, resolvePreviewLayout } from "./layout.js"
export type { PreviewLayoutPolicyInput, ResolvedPreviewLayout } from "./layout.js"
export { normalizeMetadataUrl, normalizePreviewUrl, trimUrlToken } from "./normalize.js"
export { isFigmaUrl, isLoomUrl, isXStatusUrl, isYouTubeUrl, normalizeYouTubeUrl } from "./providers/index.js"
export { extractPreviewRoutes, routePreviewUrl } from "./router.js"
export { extractPreviewTargets } from "./auth/index.js"
export { cleanField as cleanPreviewText, cleanMultilineField as cleanMultilinePreviewText } from "./text.js"
export {
  fetchLinearPreview,
  parseLinearUrl,
} from "./auth/providers/linear/index.js"
export type {
  LinearParsedUrl,
  LinearPreviewResourceType,
} from "./auth/providers/linear/index.js"
export {
  fetchNotionPreview,
  isNotionWebHost,
  parseNotionUrl,
} from "./auth/providers/notion/index.js"
export type {
  AuthenticatedPreviewProvider,
  AuthenticatedPreviewResult,
  AuthPreviewOptions,
  ParsedProviderUrl,
  PreviewAuthOwner,
  PreviewCredential,
} from "./auth/index.js"
export type { PreviewRoute } from "./router.js"
export type { ExtractedPreviewTarget } from "./auth/index.js"
export type {
  NotionParsedResourceType,
  NotionParsedUrl,
  NotionPreviewResourceType,
} from "./auth/providers/notion/index.js"
export type {
  FetchBinaryOptions,
  FetchBinaryResult,
  FetchImpl,
  FetchUrlPreviewOptions,
  LookupAddress,
  LookupFn,
  PreviewDocumentMedia,
  PreviewEmbedMedia,
  PreviewExternalVideoMedia,
  PreviewLayout,
  PreviewMedia,
  PreviewMediaType,
  PreviewPhotoMedia,
  PreviewProvider,
  PreviewDiagnostic,
  UrlPreviewResult,
} from "./types.js"

export async function fetchUrlPreview(
  targetUrl: string,
  options: FetchUrlPreviewOptions = {},
): Promise<UrlPreviewResult | null> {
  const normalized = normalizePreviewUrl(targetUrl)
  if (!normalized) {
    reportPreviewDiagnostic(options, {
      stage: "generic", provider: "generic", outcome: "blocked", code: "invalid_url", elapsedMs: 0,
    })
    return null
  }

  for (const provider of previewProviders) {
    if (!provider.canHandle(normalized)) {
      continue
    }

    const preview = await attempt("provider", provider.name, () => provider.fetch(normalized, options)).catch(() => null)
    return preview ?? (provider.exclusive ? null : attempt("generic", "generic", () => fetchGenericPreview(normalized, options)))
  }

  return attempt("generic", "generic", () => fetchGenericPreview(normalized, options))

  async function attempt(
    stage: "provider" | "generic",
    provider: UrlPreviewResult["provider"],
    run: () => Promise<UrlPreviewResult | null>,
  ): Promise<UrlPreviewResult | null> {
    const startedAt = Date.now()
    try {
      const preview = await run()
      reportPreviewDiagnostic(options, {
        stage, provider, outcome: preview ? "success" : "empty", elapsedMs: Date.now() - startedAt,
        ...(!preview ? { code: "no_metadata" } : {}),
      })
      return preview
    } catch (error) {
      reportPreviewDiagnostic(options, {
        stage, provider, outcome: "error", elapsedMs: Date.now() - startedAt, ...previewErrorDiagnostic(error),
      })
      throw error
    }
  }
}
