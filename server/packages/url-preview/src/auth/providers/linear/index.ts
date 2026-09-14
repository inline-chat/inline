import type { AuthenticatedPreviewProvider } from "../../types.js"
import { fetchLinearPreview } from "./fetcher.js"
import { parseLinearUrl } from "./parse.js"
import type { LinearParsedUrl } from "./types.js"

export const linearProvider: AuthenticatedPreviewProvider<LinearParsedUrl> = {
  provider: "linear",
  parseUrl: parseLinearUrl,
  fetch: fetchLinearPreview,
}

export { fetchLinearPreview } from "./fetcher.js"
export { parseLinearUrl } from "./parse.js"
export type { LinearParsedUrl, LinearPreviewResourceType } from "./types.js"
