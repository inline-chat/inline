/**
 * Apple clients decode stored text through C strings, so a NUL ends the
 * message there and later block ranges stop resolving. U+FFFD is one UTF-16
 * unit as well, so entity and block ranges stay valid.
 *
 * Apply this only where text leaves the server. Stored text and its
 * block-content mirror must stay byte-exact so the mirror check still holds.
 */
export function displayMessageText(text: string): string
export function displayMessageText(text: string | undefined): string | undefined
export function displayMessageText(text: string | null | undefined): string | null | undefined
export function displayMessageText(text: string | null | undefined): string | null | undefined {
  return text?.includes("\0") ? text.replaceAll("\0", "�") : text
}
