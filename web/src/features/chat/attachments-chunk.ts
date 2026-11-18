/**
 * Attachments' chunk (`web/src/features/composer/attachments.ts`): the
 * per-chat attachment drafts and their send. Loaded when the first file
 * arrives (paste, drop, the Attach button); nothing imports it statically.
 * The strip and the drop overlay are views `ComposerView` imports itself,
 * so they are in the shell chunk; `chat-attachments.ts` stands in for the
 * model until this arrives.
 */

export { attachmentSendErrorText, createAttachmentDrafts, followUploadActivity } from "../composer/attachments"

export type AttachmentsChunk = typeof import("./attachments-chunk")
