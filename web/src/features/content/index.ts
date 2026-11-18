/**
 * Message content views: media, rich blocks, attachments, bot buttons,
 * service rows and the lines around a message. Views render the render
 * models from `@inline/chat-ui`; the framework-free controllers here own
 * loading, playback, forms and timers. See README.md.
 */

export {
  ActionRunner,
  buttonDisclosure,
  COPY_PREVIEW_GRAPHEMES,
  disclosureText,
  type ButtonDisclosure,
  type ButtonPresentation,
  type GrantCheck,
  presentButton,
} from "./buttons"
export { type ContentModels, ContentMemo, DisclosureState, hasContent, messageHasContent } from "./content-memo"
export {
  type ContentDebug,
  type ContentEnv,
  type ContentEnvInput,
  type ContentHandlers,
  type ContentLayout,
  type ContentNames,
  createContentEnv,
  type OpenMediaInput,
  type PersonPresentation,
} from "./env"
export { displayFileName, downloadFileName, splitFileName, UNNAMED_FILE, type FileNameParts } from "./file-name"
export { FormController, formLockReason, type FormSubmit } from "./form-controller"
export { type Condition, GifPlaybackController, type GifPlaybackOptions } from "./gif-playback"
export { browserObjectUrls, type ObjectUrlApi, PreviewUrls, type PreviewUrlsOptions } from "./preview-urls"
export { LoadedMedia, RevealController, type RevealOptions, type RevealStatus } from "./reveal"
export { type ContentTone, RowContent } from "./row-content"
export {
  cdnMediaSources,
  type CdnMediaSourcesOptions,
  constantSource,
  type ElementPart,
  type MediaOwner,
  type MediaSource,
  type MediaSources,
  type MediaSourceState,
  mediaUrl,
  type UploadSource,
  type UploadSourceState,
} from "./sources"
export { ElapsedTimer, TransientFlag } from "./timers"
export { PlaybackGroup, VoicePlayerController, type VoicePlayerOptions, type VoiceStatus } from "./voice-player"

export { ExternalTaskCard, Attachments, UrlPreviewCard } from "./AttachmentViews"
export { BlockView, RichBlocks, StatusBadge } from "./BlockViews"
export { ActionButton, ButtonRows, CardButtons } from "./ButtonViews"
export { FormView } from "./FormView"
export { Album, BlockImage, DocumentRow, PhotoBox, VisualMedia, VoiceRow } from "./MediaViews"
export {
  allSections,
  type ContentSection,
  contentRenderer,
  MessageContent,
  MessageMedia,
  type MessageContentProps,
} from "./MessageContent"
export { RichTextView } from "./RichText"
export { MINIMUM_UPLOAD_FRACTION, ringFraction, showsUpload } from "./upload"
export { UploadOverlay } from "./UploadOverlay"
export { ForwardLine, RepliesSummary, ServiceRow, type ServiceRowProps, ViaLine } from "./ServiceViews"
