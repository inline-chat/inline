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
const inWordMark = /^[\p{M}\u200c\u200d]$/u

/**
 * Base direction of prose: the direction with more words, a tie going to the first strong
 * letter. Persian and Hebrew prose routinely opens with Latin product names, identifiers and
 * paths ("Claude Code حداقل ۲.۱ لازم دارد"), which the first-strong rule alone reads as LTR.
 * A word is a run of letters with the marks and ZWNJ/ZWJ Arabic-script words carry inside
 * them; it counts for the direction of its first letter. Apple clients apply the same rule.
 */
export function detectIsRtl(value: string): boolean | undefined {
  let rtlWords = 0
  let ltrWords = 0
  let firstStrong: boolean | undefined
  let inWord = false
  for (const scalar of value) {
    if (strongLetter.test(scalar)) {
      if (inWord) continue
      inWord = true
      const codePoint = scalar.codePointAt(0)!
      const isRtl = rtlLetterRanges.some(([start, end]) => codePoint >= start && codePoint <= end)
      if (isRtl) rtlWords += 1
      else ltrWords += 1
      firstStrong ??= isRtl
    } else if (!inWordMark.test(scalar)) {
      inWord = false
    }
  }
  if (rtlWords !== ltrWords) return rtlWords > ltrWords
  return firstStrong
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
      clearTextDirection(block.kind.disclosure.meta)
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
    case "diff":
      // Paths and diffs render LTR, like code.
      clearTextDirection(block.kind.diff.path)
      clearTextDirection(block.kind.diff.text)
      clearTextDirection(block.kind.diff.previousPath)
      return undefined
    case "meter":
      clearTextDirection(block.kind.meter.label)
      clearTextDirection(block.kind.meter.meta)
      return undefined
    case "fields":
      return aggregateTexts(text, block.kind.fields, block.kind.fields.fields.flatMap((field) => [field.label, field.value]))
    case "steps":
      return aggregateTexts(text, block.kind.steps, block.kind.steps.steps.flatMap((step) => [step.text, step.detail]))
    case "callout": {
      let aggregate = directionForText(text, block.kind.callout.title)
      clearTextDirection(block.kind.callout.title)
      for (const child of block.kind.callout.children) {
        const childDirection = annotateBlock(text, child, emitLeafDirection)
        aggregate ??= childDirection
      }
      setDirection(block.kind.callout, aggregate)
      return aggregate
    }
    case "form": {
      const form = block.kind.form
      for (const field of form.fields) {
        if (field.kind.oneofKind !== "select") continue
        // Previews render LTR and monospaced, like code.
        for (const option of field.kind.select.options) clearTextDirection(option.preview)
      }
      return aggregateTexts(text, form, [
        form.title,
        ...form.fields.flatMap((field) => [
          field.header,
          field.label,
          field.description,
          ...(field.kind.oneofKind === "select"
            ? field.kind.select.options.flatMap((option) => [option.label, option.description])
            : []),
        ]),
      ])
    }
    case "planProposal": {
      const plan = block.kind.planProposal
      let aggregate = directionForText(text, plan.title)
      clearTextDirection(plan.title)
      for (const child of plan.children) {
        const childDirection = annotateBlock(text, child, emitLeafDirection)
        aggregate ??= childDirection
      }
      setDirection(plan, aggregate)
      return aggregate
    }
    case "approval": {
      const approval = block.kind.approval
      // Commands and working directories render LTR and monospaced.
      clearTextDirection(approval.command)
      clearTextDirection(approval.cwd)
      let aggregate = directionForText(text, approval.title) ?? directionForText(text, approval.reason)
      clearTextDirection(approval.title)
      clearTextDirection(approval.reason)
      for (const child of approval.children) {
        const childDirection = annotateBlock(text, child, emitLeafDirection)
        aggregate ??= childDirection
      }
      setDirection(approval, aggregate)
      return aggregate
    }
    case "review": {
      const review = block.kind.review
      // Paths render LTR, like code.
      for (const finding of review.findings) clearTextDirection(finding.path)
      return aggregateTexts(text, review, [
        review.title,
        review.summary,
        ...review.findings.flatMap((finding) => [finding.title, finding.body]),
      ])
    }
    case "taskSuggestion":
      return aggregateTexts(text, block.kind.taskSuggestion, [block.kind.taskSuggestion.title, block.kind.taskSuggestion.brief])
    case "nextStep":
      return aggregateTexts(text, block.kind.nextStep, [block.kind.nextStep.recap, block.kind.nextStep.question])
    case "promptSuggestions":
      return aggregateTexts(
        text,
        block.kind.promptSuggestions,
        block.kind.promptSuggestions.prompts.map((prompt) => prompt.label),
      )
    case "widget":
    case undefined:
      return undefined
    default:
      block.kind satisfies never
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
  return detectIsRtl(
    text.slice(Number(range.offset), Number(range.offset + range.length)),
  )
}

/** One direction for a container from its first strong text; leaves carry none. */
function aggregateTexts(
  text: string,
  target: { isRtl?: boolean },
  ranges: readonly (BlockText | undefined)[],
): boolean | undefined {
  let aggregate: boolean | undefined
  for (const range of ranges) {
    aggregate ??= directionForText(text, range)
    clearTextDirection(range)
  }
  setDirection(target, aggregate)
  return aggregate
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
