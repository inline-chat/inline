import { loomProvider } from "./loom.js"
import { youtubeProvider } from "./youtube.js"
import type { UrlPreviewProvider } from "./types.js"

export const previewProviders: readonly UrlPreviewProvider[] = [loomProvider, youtubeProvider]

export { isLoomUrl } from "./loom.js"
export { isYouTubeUrl, normalizeYouTubeUrl } from "./youtube.js"
