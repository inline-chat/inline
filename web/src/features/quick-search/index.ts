/**
 * Quick Search (Cmd/Ctrl+K). Wire it to a session with `wireQuickSearch`,
 * mount `QuickSearchPalette` once in the signed-in shell. See README.md.
 */

export { QuickSearchPalette, type QuickSearchPaletteProps } from "./QuickSearchPalette"
export {
  QuickSearchPaletteController,
  type QuickSearchPaletteControllerOptions,
  type RowPresentation,
  type RowVisual,
} from "./palette-controller"
export {
  quickSearchUsageStorageKey,
  sessionQuickSearchRows,
  wireQuickSearch,
  type KeyboardLayers,
  type QuickSearchWiring,
  type QuickSearchWiringOptions,
} from "./wiring"
export {
  formatHitDate,
  highlightSegments,
  itemLabel,
  kindLabel,
  messageTitleColumn,
  messageTitleMaxWidth,
  paletteKeyAction,
  pointerIntent,
  sameItem,
  shortcutKeys,
  type PaletteKeyAction,
  type TextSegment,
} from "./present"
export {
  CoreRemoteSearchError,
  coreRemoteRequest,
  createCoreMessageSource,
  createCoreRemoteSource,
  createNoopRemoteSource,
  SEARCH_USERS_LIMIT,
  type CoreMessageSource,
  type CoreRemoteSource,
  type CoreRemoteSourceOptions,
  type RemoteFailureReason,
  type RemotePeopleState,
} from "./core-sources"
