import type { AuthenticatedPreviewProvider } from "../../types.js"
import { fetchNotionPreview } from "./fetcher.js"
import { parseNotionUrl } from "./parse.js"
import type { NotionParsedUrl } from "./types.js"

export const notionProvider: AuthenticatedPreviewProvider<NotionParsedUrl> = {
  provider: "notion",
  parseUrl: parseNotionUrl,
  fetch: fetchNotionPreview,
}

export { fetchNotionPreview } from "./fetcher.js"
export { isNotionWebHost, parseNotionUrl } from "./parse.js"
export type { NotionParsedResourceType, NotionParsedUrl, NotionPreviewResourceType } from "./types.js"
