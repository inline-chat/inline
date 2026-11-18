/**
 * Message views: timeline rows (messages, day separators, the unread line,
 * the loading row), row actions, and the pure helpers that prepare their
 * data. See README.md for the rules a caller keeps.
 */

export {
  MESSAGE_ROW_ATTRIBUTE,
  MessageActionsController,
  menuEntries,
  QUICK_ACTION_ATTRIBUTE,
  quickActions,
  type ReactionPickerAnchor,
  type MessageAction,
  type MessageActionIcon,
  type MessageActionInvocation,
  type MessageActionsOptions,
  type MessageActionsSource,
} from "./actions"
export { emojiSize, isEmojiGrapheme, type EmojiSize } from "./emoji"
export { rowLayout, type BubbleKind, type RowLayout, type RowLayoutInput } from "./layout"
export {
  createMessageTimes,
  presentReply,
  presentSender,
  type MessageTimes,
  type ReplyPresentation,
  type SenderPresentation,
} from "./presentation"
export { compareCodePoints, orderReactions, reactionChipTooltip, reactionLabel } from "./reactions"
export { statePresentation, type StateGlyph, type StatePresentation } from "./state"
export { createMessageTextMemo, MessageTextMemo, type MessageTextContent, type MessageTextSource } from "./text-memo"
export {
  MessageRowSignalView,
  MessageRowView,
  type MessageRowContext,
  type MessageRowHandlers,
  type MessageRowViewProps,
} from "./MessageRowView"
export { MessageActionsMenu, MessageActionsRegion, QuickActions } from "./RowActions"
export {
  FindHighlights,
  findOccurrences,
  normalizeRanges,
  sameRanges,
  type FindRange,
  type FindRanges,
} from "./find"
export {
  CONTENT_SLOT_SECTIONS,
  CONTENT_SLOTS,
  planContent,
  slottedContent,
  type ContentPlan,
  type ContentRenderOptions,
  type ContentSlot,
  type MessageRowContentSource,
} from "./content-slots"
export {
  DaySeparatorRow,
  LoadingOlderRow,
  UnreadLineRow,
  type DaySeparatorRowProps,
  type LoadingOlderRowProps,
  type UnreadLineRowProps,
} from "./Separators"
