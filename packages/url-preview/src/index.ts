import { fetchGenericPreview } from "./providers/generic.js"
import { previewProviders } from "./providers/index.js"
import { normalizePreviewUrl } from "./normalize.js"
import type { FetchUrlPreviewOptions, UrlPreviewResult } from "./types.js"

export { UrlPreviewError } from "./errors.js"
export {
  authenticatedPreviewProviders,
  fetchAuthenticatedUrlPreview,
  parseAuthenticatedPreviewUrl,
} from "./auth/index.js"
export { extractPreviewUrl, extractPreviewUrls } from "./extract.js"
export { filterPreviewUrl, isBlockedHostname, isBlockedIp } from "./filters.js"
export { fetchBinary } from "./network.js"
export { normalizeMetadataUrl, normalizePreviewUrl, trimUrlToken } from "./normalize.js"
export { isLoomUrl, isYouTubeUrl, normalizeYouTubeUrl } from "./providers/index.js"
export { extractPreviewRoutes, routePreviewUrl } from "./router.js"
export { extractPreviewTargets } from "./auth/index.js"
export { cleanField as cleanPreviewText } from "./text.js"
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
  UrlPreviewResult,
} from "./types.js"

export async function fetchUrlPreview(
  targetUrl: string,
  options: FetchUrlPreviewOptions = {},
): Promise<UrlPreviewResult | null> {
  const normalized = normalizePreviewUrl(targetUrl)
  if (!normalized) {
    return null
  }

  for (const provider of previewProviders) {
    if (!provider.canHandle(normalized)) {
      continue
    }

    const preview = await provider.fetch(normalized, options).catch(() => null)
    return preview ?? (provider.exclusive ? null : fetchGenericPreview(normalized, options))
  }

  return fetchGenericPreview(normalized, options)
}
