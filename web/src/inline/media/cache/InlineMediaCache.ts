import type { UserID } from "@inline/ids"

export type InlineMediaCacheOptions = {
  accountId: UserID
  maxBytes?: number
}

export interface InlineMediaCache {
  get(key: string): Promise<Blob | undefined>
  put(key: string, blob: Blob): Promise<void>
}

export const defaultInlineMediaCacheBytes = 256 * 1024 * 1024
