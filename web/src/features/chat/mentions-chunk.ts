/**
 * Mentions' chunk: the participants model (`web/src/features/chat-info/`),
 * the `@` suggestions and the add policy (`web/src/features/mentions/`),
 * put together per chat by `mention-models.ts`. Loaded on the first `@` in
 * a composer (or after a send with a mention); nothing imports it
 * statically.
 */

export { createChatMentionModels } from "./mention-models"

export type MentionsChunk = typeof import("./mentions-chunk")
