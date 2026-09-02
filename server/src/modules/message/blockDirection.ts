import type { Block, BlockContent, BlockText } from "@inline-chat/protocol/core"

// Explicit RTL-script ranges keep the wire projection independent from a
// client's locale and bidi implementation. Non-letter characters, including
// digits, punctuation, emoji, combining marks, and bidi controls, are neutral
// for this first-strong decision.
const rtlLetterRanges: ReadonlyArray<readonly [number, number]> = [
  [0x0590, 0x05ff], // Hebrew
  [0x0600, 0x06ff], // Arabic
  [0x0700, 0x074f], // Syriac
  [0x0750, 0x077f], // Arabic Supplement
  [0x0780, 0x07bf], // Thaana
  [0x07c0, 0x07ff], // NKo
  [0x0800, 0x083f], // Samaritan
  [0x0840, 0x085f], // Mandaic
  [0x0860, 0x086f], // Syriac Supplement
  [0x0870, 0x089f], // Arabic Extended-B
  [0x08a0, 0x08ff], // Arabic Extended-A
  [0xfb1d, 0xfb4f], // Hebrew presentation forms
  [0xfb50, 0xfdff], // Arabic presentation forms-A
  [0xfe70, 0xfeff], // Arabic presentation forms-B
  [0x10840, 0x1085f], // Imperial Aramaic
  [0x10860, 0x1087f], // Palmyrene
  [0x10880, 0x108af], // Nabataean
  [0x108e0, 0x108ff], // Hatran
  [0x10900, 0x1091f], // Phoenician
  [0x10920, 0x1093f], // Lydian
  [0x10980, 0x109ff], // Meroitic
  [0x10a00, 0x10a5f], // Kharoshthi
  [0x10a60, 0x10a7f], // Old South Arabian
  [0x10a80, 0x10a9f], // Old North Arabian
  [0x10ac0, 0x10aff], // Manichaean
  [0x10b00, 0x10b3f], // Avestan
  [0x10b40, 0x10b5f], // Inscriptional Parthian
  [0x10b60, 0x10b7f], // Inscriptional Pahlavi
  [0x10b80, 0x10baf], // Psalter Pahlavi
  [0x10c00, 0x10c4f], // Old Turkic
  [0x10c80, 0x10cff], // Old Hungarian
  [0x10d00, 0x10d8f], // Hanifi Rohingya and Garay
  [0x10e80, 0x10ebf], // Yezidi
  [0x10f00, 0x10fff], // Old Sogdian through Elymaic
  [0x1e800, 0x1e8df], // Mende Kikakui
  [0x1e900, 0x1e95f], // Adlam
  [0x1ee00, 0x1eeff], // Arabic Mathematical Alphabetic Symbols
]

const strongLetter = /^[\p{L}\p{Nl}]$/u

export function detectFirstStrongIsRtl(value: string): boolean | undefined {
  for (const scalar of value) {
    if (!strongLetter.test(scalar)) continue
    const codePoint = scalar.codePointAt(0)!
    return rtlLetterRanges.some(([start, end]) => codePoint >= start && codePoint <= end)
  }
  return undefined
}

export function annotateBlockContentDirections(text: string, content: BlockContent): void {
  for (const block of content.blocks) {
    annotateBlock(text, block, true)
  }
}

function annotateBlock(
  text: string,
  block: Block,
  emitLeafDirection: boolean,
): boolean | undefined {
  switch (block.kind.oneofKind) {
    case "paragraph":
      return annotateLeafText(text, block.kind.paragraph, emitLeafDirection)
    case "heading":
      return annotateLeafText(text, block.kind.heading.text, emitLeafDirection)
    case "footer":
      return annotateLeafText(text, block.kind.footer, emitLeafDirection)
    case "math":
      clearTextDirection(block.kind.math)
      return undefined
    case "code":
      clearTextDirection(block.kind.code.text)
      // Clients force code LTR. It does not decide a surrounding prose group.
      return undefined
    case "list": {
      let aggregate: boolean | undefined
      for (const item of block.kind.list.items) {
        for (const child of item.children) {
          const childDirection = annotateBlock(text, child, false)
          aggregate ??= childDirection
        }
      }
      setDirection(block.kind.list, aggregate)
      return aggregate
    }
    case "disclosure": {
      let aggregate = directionForText(text, block.kind.disclosure.summary)
      clearTextDirection(block.kind.disclosure.summary)
      for (const child of block.kind.disclosure.children) {
        const childDirection = annotateBlock(text, child, emitLeafDirection)
        aggregate ??= childDirection
      }
      setDirection(block.kind.disclosure, aggregate)
      return aggregate
    }
    case "quote": {
      let aggregate: boolean | undefined
      for (const child of block.kind.quote.children) {
        const childDirection = annotateBlock(text, child, emitLeafDirection)
        aggregate ??= childDirection
      }
      setDirection(block.kind.quote, aggregate)
      return aggregate
    }
    case "table": {
      let aggregate: boolean | undefined
      for (const row of block.kind.table.rows) {
        for (const cell of row.cells) {
          const cellDirection = directionForText(text, cell)
          clearTextDirection(cell)
          aggregate ??= cellDirection
        }
      }
      setDirection(block.kind.table, aggregate)
      return aggregate
    }
    case "image":
      clearTextDirection(block.kind.image.alt)
      return undefined
    case "album":
      for (const image of block.kind.album.images) clearTextDirection(image.alt)
      return undefined
    case "separator":
      return undefined
    default:
      return undefined
  }
}

function annotateLeafText(
  text: string,
  range: BlockText | undefined,
  emit: boolean,
): boolean | undefined {
  const direction = directionForText(text, range)
  if (emit && direction !== undefined && range) {
    range.isRtl = direction
  } else {
    clearTextDirection(range)
  }
  return direction
}

function directionForText(text: string, range: BlockText | undefined): boolean | undefined {
  if (!range) return undefined
  return detectFirstStrongIsRtl(
    text.slice(Number(range.offset), Number(range.offset + range.length)),
  )
}

function clearTextDirection(range: BlockText | undefined): void {
  if (range) delete range.isRtl
}

function setDirection(target: { isRtl?: boolean }, direction: boolean | undefined): void {
  if (direction === undefined) {
    delete target.isRtl
  } else {
    target.isRtl = direction
  }
}
