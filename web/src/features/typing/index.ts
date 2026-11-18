/** Compose activity: who is typing (incoming) and this user's own (outgoing). See README.md. */
export { composeStatus, sameStatus, typingText, type ComposeStatus, type ComposeStatusInput, type TypingLength } from "./presentation"
export {
  createChatTyping,
  createComposeActivityIndex,
  isDirectChat,
  type ChatTypingModel,
  type ComposeActivityIndex,
  type RowActivity,
} from "./typing-model"
export { createComposeReporter, type ComposeReporter, type OutgoingActivityKind } from "./outgoing"
export { TypingLine } from "./TypingLine"
