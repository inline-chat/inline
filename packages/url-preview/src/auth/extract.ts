import { extractPreviewRoutes, routePreviewUrl, type PreviewRoute } from "../router.js"

export function extractPreviewTargets(
  text: string,
  candidates: readonly string[] = [],
  options: { limit?: number } = {},
): PreviewRoute[] {
  return extractPreviewRoutes(text, candidates, options)
}

export { routePreviewUrl }
export type ExtractedPreviewTarget = PreviewRoute
