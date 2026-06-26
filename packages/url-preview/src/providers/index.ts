import { loomProvider } from "./loom.js"
import { xProvider } from "./x.js"
import { youtubeProvider } from "./youtube.js"
import type { UrlPreviewProvider } from "./types.js"

export const previewProviders: readonly UrlPreviewProvider[] = [loomProvider, youtubeProvider, xProvider]

export { isLoomUrl } from "./loom.js"
export { isXStatusUrl } from "./x.js"
export { isYouTubeUrl, normalizeYouTubeUrl } from "./youtube.js"
