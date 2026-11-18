/**
 * Emoji: the light half. Safe to import from code in the initial bundle:
 * nothing here imports the emoji table, the search engine, the pickers or
 * the UI kit's layers. The pickers are in `./chunk` (load it with
 * `import()`), and the table loads on first use through the services'
 * loader. See README.md.
 */

export { createEmojiSuggest, type EmojiSuggest, type EmojiSuggestion, type EmojiSuggestOptions } from "./composer-source"
export { emojiName, reactionChipLabel, reactionTooltip, type Reactor } from "./display"
export type { EmojiEngine, EmojiInfo, EmojiSection, SearchOptions, UsageScores } from "./engine"
export { EMOJI_FONT_STACK } from "./font"
export { isMessageEmoji, prioritizingMessageEmojis, QUICK_REACTIONS, quickRow, suggestedReactions, type QuickReaction } from "./quick"
export {
  createEmojiEngineLoader,
  createEmojiServices,
  importEmojiEngine,
  type EmojiEngineLoader,
  type EmojiLoadStatus,
  type EmojiServices,
  type EmojiServicesOptions,
} from "./services"
export { canvasEmojiProbe, createEmojiSupport, idleSchedule, type EmojiProbe, type EmojiSupport } from "./support"
export { applySkinTone, containsSkinTone, SKIN_TONE_LABELS, SKIN_TONES, usageKey, type SkinTone } from "./tone"
export {
  EmojiUsage,
  localStorageKeyValueStore,
  memoryKeyValueStore,
  normalizedEmoji,
  USAGE_KEYS,
  type KeyValueStore,
} from "./usage"

/** The pickers' chunk, for `import()`. */
export type EmojiChunk = typeof import("./chunk")
