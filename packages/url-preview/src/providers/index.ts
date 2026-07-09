import { figmaProvider } from "./figma.js"
import { loomProvider } from "./loom.js"
import { xProvider } from "./x.js"
import { youtubeProvider } from "./youtube.js"
import type { UrlPreviewProvider } from "./types.js"

export const previewProviders: readonly UrlPreviewProvider[] = [figmaProvider, loomProvider, youtubeProvider, xProvider]

export { isFigmaUrl } from "./figma.js"
export { isLoomUrl } from "./loom.js"
export { isXStatusUrl } from "./x.js"
export { isYouTubeUrl, normalizeYouTubeUrl } from "./youtube.js"
