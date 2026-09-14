import type { FetchUrlPreviewOptions, UrlPreviewResult } from "../types.js"

export type UrlPreviewProvider = {
  name: UrlPreviewResult["provider"]
  canHandle(url: string): boolean
  exclusive?: boolean
  fetch(url: string, options: FetchUrlPreviewOptions): Promise<UrlPreviewResult | null>
}
