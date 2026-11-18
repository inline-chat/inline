/** `@` mention suggestions and the mention add policy. See README.md. */
export {
  createMentionSuggestions,
  mentionLabel,
  recentSenders,
  RECENT_SENDER_WINDOW,
  type DirectPeer,
  type MentionCandidate,
  type MentionSource,
  type MentionSuggestion,
  type MentionSuggestions,
  type MentionSuggestionsOptions,
  type MentionTarget,
} from "./suggest"
export {
  AUTO_ADD_MESSAGE_LIMIT,
  canRemoveParticipants,
  mentionAddContext,
  mentionAddDecision,
  mentionedUserIds,
  policyMessageCount,
  type MentionAddContext,
  type MentionAddDecision,
} from "./add-policy"
