/**
 * Find in chat (Mod+F): a model per chat pane, the bar over the chat, and
 * the commands. See README.md for mounting it in the chat pane.
 */

export { FindBar, type FindBarProps } from "./FindBar"
export { FindBarController, type FindBarControllerOptions, type FindRowPresentation, type FindSender } from "./find-bar-controller"
export {
  FindInChatModel,
  findTiming,
  selectionSeed,
  type FindHit,
  type FindJump,
  type FindModelOptions,
  type FindPosition,
  type FindState,
  type FindTiming,
} from "./find-model"
export {
  coreFindSource,
  coreServerFindSource,
  coreServerSearchRequest,
  FindServerError,
  type FindCount,
  type FindInChatSource,
  type FindPage,
  type FindPageRequest,
  type FindServerPage,
  type FindServerPageRequest,
  type FindServerSource,
} from "./find-source"
export {
  findCommandIds,
  findShortcuts,
  registerFindCommands,
  type FindCommandTarget,
  type FindCommandsOptions,
} from "./commands"
export { chatSelectionText } from "./selection"
export {
  ariaShortcut,
  findKeyAction,
  findListMetrics,
  formatFindDate,
  listWindow,
  revealRow,
  shortcutHint,
  snippetRuns,
  type FindKeyAction,
  type ListWindow,
  type TextRun,
} from "./present"
