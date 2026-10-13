/** Fixed transfer geometry shared by realtime V3 upload and download clients. */
export const INLINE_TRANSFER_PART_SIZE = 512 * 1024
export const INLINE_UPLOAD_MAX_PARTS = 1_000
export const INLINE_TRANSFER_MAX_LOCATOR_ID = 2_147_483_647n

/** Decimal byte limits, shared by native admission and legacy HTTP uploads. */
export const INLINE_MEDIA_UPLOAD_MAX_BYTES = {
  photo: 40_000_000,
  video: 500_000_000,
  document: 500_000_000,
  voice: 20_000_000,
} as const
