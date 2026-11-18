export * from "./types"
export {
  atomContaining,
  atomsIntersecting,
  compareEntities,
  entitiesEqual,
  markKey,
  markOf,
  normalizeEntities,
  splitsSurrogate,
} from "./entities"
export {
  activeMarks,
  collapsed,
  createDoc,
  emptyDoc,
  expandRange,
  isCollapsed,
  normalizeSelection,
  replace,
  replaceEntities,
  selectionRange,
  setSelection,
  withContent,
  type DocInit,
  type Insertion,
} from "./doc"
export * from "./ops"
export * from "./history"
export * from "./triggers"
export { applyBoldShortcut } from "./shortcuts"
export { docLines, lineRuns, type Line, type Run } from "./lines"
export { normalizeText } from "./text"
export {
  lineEndOf,
  lineStartOf,
  nextGrapheme,
  nextWordBoundary,
  previousGrapheme,
  previousWordBoundary,
} from "./segment"
