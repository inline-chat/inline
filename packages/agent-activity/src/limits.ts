import type { Doc } from "./doc.js"
import type { Block } from "./protocol.js"

/** Server limits (`server/src/modules/encryption/limits.ts`, `blockContentLimits`). */
export const MAX_TEXT_UTF16 = 100_000
export const MAX_TEXT_BYTES = 400_000
export const MAX_BLOCKS = 1_024
export const MAX_DEPTH = 16

export type DocSize = { utf16: number; bytes: number; blocks: number; depth: number }

/** Counts as the server's validator does: disclosures, callouts, quotes and list items nest one level deeper. */
export function docSize(doc: Doc): DocSize {
  const size: DocSize = { utf16: doc.text.length, bytes: Buffer.byteLength(doc.text, "utf8"), blocks: 0, depth: 0 }
  const walk = (blocks: readonly Block[], depth: number) => {
    if (blocks.length > 0) size.depth = Math.max(size.depth, depth)
    for (const block of blocks) {
      size.blocks += 1
      switch (block.kind.oneofKind) {
        case "disclosure":
          walk(block.kind.disclosure.children, depth + 1)
          break
        case "callout":
          walk(block.kind.callout.children, depth + 1)
          break
        case "quote":
          walk(block.kind.quote.children, depth + 1)
          break
        case "list":
          for (const item of block.kind.list.items) walk(item.children, depth + 1)
          break
        default:
          break
      }
    }
  }
  walk(doc.blockContent.blocks, 0)
  return size
}

/** Within `share` of every limit (depth always in full). */
export function docWithin(doc: Doc, share = 1): boolean {
  const size = docSize(doc)
  return size.utf16 <= MAX_TEXT_UTF16 * share
    && size.bytes <= MAX_TEXT_BYTES * share
    && size.blocks <= MAX_BLOCKS * share
    && size.depth <= MAX_DEPTH
}

/** A progress message continues in a new one past 80% of any limit, leaving room for rows still growing. */
export function progressFits(doc: Doc): boolean {
  return docWithin(doc, 0.8)
}
