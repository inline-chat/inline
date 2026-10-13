import { INLINE_MEDIA_UPLOAD_MAX_BYTES } from "@inline-chat/protocol/transfers"

export const MEDIA_UPLOAD_MAX_BYTES = INLINE_MEDIA_UPLOAD_MAX_BYTES

// One main file, one photo thumbnail, and room for multipart fields/boundaries.
export const MAX_HTTP_UPLOAD_BYTES = Math.max(...Object.values(MEDIA_UPLOAD_MAX_BYTES)) +
  MEDIA_UPLOAD_MAX_BYTES.photo + 1_000_000
