export { buildTextDocument, marksWith, noMarks, type TextRenderOptions } from "./build"
export { changedBlockKeys, reuseUnchanged, updateTextDocument } from "./reuse"
export { applyHighlights, highlightTextDocument, MAX_HIGHLIGHT_RANGES, normalizeHighlightRanges } from "./highlight"
export {
  copyText,
  defaultPreviewLength,
  documentPreview,
  documentText,
  previewText,
  type CopyOptions,
  type PreviewOptions,
} from "./plain"
export {
  ellipsis,
  firstGrapheme,
  graphemeEndAtOrAfter,
  graphemeStartAtOrBefore,
  splitsSurrogatePair,
  truncateGraphemes,
} from "./graphemes"
export * from "./types"
