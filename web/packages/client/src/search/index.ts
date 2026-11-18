/**
 * Local message search: an FTS5 index in the replica, kept in step with
 * message rows, and the queries Quick Search and find in chat need. See
 * README.md.
 */
export {
  COUNT_CAP,
  createMessageSearch,
  DEFAULT_SEARCH_LIMIT,
  FIND_IN_CHAT_PAGE,
  isMessageSearchStore,
  MAX_SEARCH_LIMIT,
  MessageSearch,
  RELEVANCE_WINDOW,
  type FindInChatPage,
  type FindInChatRequest,
  type MessageSearchCount,
  type MessageSearchHit,
  type MessageSearchIndexStatus,
  type MessageSearchOptions,
  type MessageSearchPage,
  type MessageSearchRequest,
  type MessageSearchSort,
  type MessageSearchStore,
} from "./engine"
export { matchRanges, messageSnippet, type TextRange } from "./highlight"
export { indexText, SEARCH_NORMALIZER_VERSION, tokenize, type SearchToken } from "./normalize"
export {
  isSearchableQuery,
  MAX_QUERY_LENGTH,
  parseQuery,
  type ParsedQuery,
  type QueryGroup,
} from "./query"
