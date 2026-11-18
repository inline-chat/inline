/**
 * What every message's content shares: the media layer, the shared
 * controllers (preview URLs, revealed media, one voice note at a time, GIF
 * playback), the handlers the content calls, and how names resolve. Create
 * one per list (or per app) and keep its identity: a new environment
 * re-renders every row's content.
 */

import type {
  ButtonModel,
  ForwardHeaderModel,
  FormSubmissionValue,
  SafeLinkOptions,
  ServiceLink,
  TextRenderOptions,
  TimelineStyle,
} from "@inline/chat-ui"
import type { MessageTextHandlers } from "@inline/chat-ui/react"
import type {
  ForwardHeader,
  MediaContent,
  MessageRowId,
  PeerRef,
  PhotoInfo,
  VideoInfo,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import type { GrantCheck } from "./buttons"
import { GifPlaybackController } from "./gif-playback"
import { PreviewUrls } from "./preview-urls"
import { LoadedMedia, type RevealStatus } from "./reveal"
import { cdnMediaSources, type MediaSources } from "./sources"
import { PlaybackGroup } from "./voice-player"

export type OpenMediaInput = {
  readonly rowId: MessageRowId
  /** The model key (`photo:<id>`, `image@0`, ...). */
  readonly key: string
  readonly kind: "photo" | "video" | "gif" | "image"
  readonly photo: PhotoInfo | undefined
  readonly video: VideoInfo | undefined
  /** Position in an album. */
  readonly index?: number
}

export type ContentHandlers = MessageTextHandlers & {
  /** A photo, video, GIF or block image was activated (the media viewer is later work). */
  readonly onOpenMedia?: (input: OpenMediaInput) => void
  /** The download affordance of a document row. */
  readonly onDownload?: (input: { readonly rowId: MessageRowId; readonly media: MediaContent }) => void
  /** A form's one submit. Resolve when the server accepted it; reject to let the user try again. */
  readonly onSubmitForm?: (input: {
    readonly rowId: MessageRowId
    readonly formId: string
    readonly values: readonly FormSubmissionValue[]
  }) => Promise<void>
  /**
   * A bot or agent-card button: callback, copy, open link, compose, or a URL
   * button with a confirm step. Return a promise for a callback to show a
   * spinner until the bot answers. Plain `openUrl` web links are anchors and
   * go through `onExternalLink` instead.
   */
  readonly onAction?: (input: { readonly rowId: MessageRowId; readonly button: ButtonModel }) => Promise<void> | void
  /** Put text in the composer after any draft, never sending (prompt suggestions). */
  readonly onCompose?: (text: string) => void
  /** Open a chat or user (a task suggestion's started thread). */
  readonly onOpenPeer?: (peer: PeerRef, messageId?: MessageID) => void
  /** The forward header was activated. */
  readonly onForward?: (target: NonNullable<ForwardHeaderModel["target"]>) => void
  /** The reply thread summary was activated. */
  readonly onOpenReplies?: (input: { readonly rowId: MessageRowId; readonly chatId: ChatID }) => void
  /** A link segment of a service row. */
  readonly onServiceLink?: (link: ServiceLink) => void
  /** Copy text (code blocks, monospace fields). The app writes the clipboard. */
  readonly onCopyText?: (text: string) => void
}

export type PersonPresentation = { readonly name: string; readonly seed?: string; readonly photoUrl?: string }

/** Names come from the caller, so the content views stay free of app state. */
export type ContentNames = {
  readonly user?: (userId: UserID) => PersonPresentation | undefined
  /** Title for the forward line: the source chat's title or the original sender's short name. */
  readonly forwardTitle?: (forward: ForwardHeader) => string | undefined
  /** A bot's current short name ("Sent via"). */
  readonly botName?: (userId: UserID) => string | undefined
}

export type ContentLayout = {
  /** Width for the content in CSS px (default 420, the bubble maximum). */
  readonly availableWidth?: number
  readonly style?: TimelineStyle
  readonly locale?: string
}

/** Hooks for labs and diagnostics. Called while rendering; keep them cheap and side-effect free for the app. */
export type ContentDebug = {
  readonly onBlockRender?: (rowId: MessageRowId, key: string) => void
  readonly onMediaStatus?: (rowId: MessageRowId, key: string, status: RevealStatus) => void
}

export type ContentEnv = {
  readonly sources: MediaSources
  readonly previews: PreviewUrls
  readonly loaded: LoadedMedia
  readonly playback: PlaybackGroup
  readonly gif: GifPlaybackController
  readonly handlers: ContentHandlers
  readonly names: ContentNames
  /** The viewer, for the forward header. */
  readonly me: UserID | undefined
  /** The app's grant check for buttons and forms; without it, everything is enabled and the server decides. */
  readonly canUse: GrantCheck | undefined
  readonly layout: ContentLayout
  readonly text: TextRenderOptions | undefined
  readonly links: SafeLinkOptions | undefined
  /** Seconds since the epoch, for task suggestions past their expiry. */
  readonly now: (() => number) | undefined
  readonly debug: ContentDebug | undefined
}

export type ContentEnvInput = Partial<ContentEnv>

/** An environment with defaults: the CDN sources stand-in, fresh shared controllers, no handlers. */
export const createContentEnv = (input: ContentEnvInput = {}): ContentEnv => ({
  sources: input.sources ?? cdnMediaSources(),
  previews: input.previews ?? new PreviewUrls(),
  loaded: input.loaded ?? new LoadedMedia(),
  playback: input.playback ?? new PlaybackGroup(),
  gif: input.gif ?? new GifPlaybackController(),
  handlers: input.handlers ?? {},
  names: input.names ?? {},
  me: input.me,
  canUse: input.canUse,
  layout: input.layout ?? {},
  text: input.text,
  links: input.links,
  now: input.now,
  debug: input.debug,
})
