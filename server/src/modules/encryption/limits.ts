/** Conservative plaintext ceiling shared by both encryption formats. */
export const MAX_ENCRYPTED_DATA_LENGTH = 20_000

/**
 * Message text is a separately bounded product payload. One UTF-16 unit can
 * expand to multiple UTF-8 bytes, so retain enough encrypted-byte headroom for
 * every string admitted by the user-visible text ceiling.
 */
export const MAX_MESSAGE_TEXT_UTF16_UNITS = 100_000
export const MAX_MESSAGE_TEXT_UTF8_BYTES = 400_000
export const MAX_MESSAGE_ENTITIES_BYTES = 512 * 1024
