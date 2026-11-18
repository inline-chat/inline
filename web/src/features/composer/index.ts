/** The composer feature: create a `ComposerModel` and mount `ComposerView`. See README.md. */

export { ComposerView, type ComposerViewProps } from "./ComposerView"
export {
  createComposerModel,
  type ComposerBanner,
  type ComposerModel,
  type ComposerModelOptions,
  type MessagePreview,
  type SurfaceOptions,
} from "./model"
export { createComposerAutocomplete, type ComposerAutocomplete, type ComposerSuggestion, type SuggestFn } from "./autocomplete"
export { isEditableTarget } from "./dom"
export { listenTypeAnywhere } from "./type-anywhere"
export { escapeLeavesComposer, sendErrorText, sendHint, sendShortcut, shouldFocusForKey } from "./text"
export {
  ATTACHMENT_INFO_TIMEOUT_MS,
  type AttachmentDrafts,
  type AttachmentLimits,
  type AttachmentsClient,
  type AttachmentStatus,
  attachmentSendErrorText,
  type ComposerAttachments,
  type ComposerAttachmentsOptions,
  createAttachmentDrafts,
  createComposerAttachments,
  MAX_ATTACHMENT_BYTES,
  MAX_ATTACHMENTS,
  type PendingAttachment,
  withAttachments,
} from "./attachments"
export { AttachButton, AttachmentStrip, DropOverlay, useDropTarget } from "./AttachmentStrip"
export { DropTarget, type DropTargetOptions } from "./drop-target"
