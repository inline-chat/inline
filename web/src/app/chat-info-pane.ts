/**
 * The `chatInfo` destination's model options (`web/src/features/chat-info/README.md`):
 * the session's client, dialog row, intents and health; tab changes replace
 * the pane's destination (no new history entry); a participant opens their
 * profile in the same pane. Framework-free, so the wiring is tested.
 *
 * With the app's services also: the media tabs (Media, Files, Voice, Links)
 * over the session's media layer, photos and videos opening in the app's
 * media viewer (stepping through the tab's own rows), files saved as the
 * message list saves them, links through the app's link handler; and the
 * outcomes of Add People and Remove as toasts.
 */

import type { MessageRow, RowKey } from "@inline/core-protocol"
import type { ChatID } from "@inline/ids"
import { computed } from "@inline/reactive"
import type { ToastTone } from "@inline/ui"
import type { ChatInfoTab, PaneId } from "@inline/view"
import type { AccountSession } from "@inline/view/features"
import type { ChatInfoMediaOptions, ChatInfoModel, ChatInfoModelOptions } from "../features/chat-info/chat-info-model"
import type { OpenMediaInput } from "../features/content/env"

export type ChatInfoToast = { readonly id?: string; readonly title: string; readonly description?: string; readonly tone?: ToastTone }

/** What the pane hands the media tabs. */
export type ChatInfoMediaInput = {
  /** The session's media layer (`ShellModel.mediaSources` over `createCoreMediaSources`; made on first use, shared with the panes). */
  readonly sources: () => ChatInfoMediaOptions["sources"]
  /** The app's media viewer: the photo or video, the rows to step through (oldest first), the sources. */
  readonly openMedia?: (input: OpenMediaInput, rows: () => readonly MessageRow[], sources: ChatInfoMediaOptions["sources"]) => void
  /** A file row's Download (`downloadMessageFile`, as the message list's). */
  readonly download?: ChatInfoMediaOptions["onDownload"]
  /** A link row (the app's link handler). */
  readonly openLink?: (url: string) => void
}

export type ChatInfoPaneInput = {
  readonly session: Pick<AccountSession, "client" | "userId" | "dialogFor" | "intents" | "health" | "workspace">
  readonly paneId: PaneId
  readonly chatId: ChatID
  readonly tab?: ChatInfoTab
  readonly copyText?: (text: string) => Promise<unknown> | void
  readonly media?: ChatInfoMediaInput
  /** The shell's toasts, for the outcomes of adding and removing participants. */
  readonly toast?: (toast: ChatInfoToast) => void
  /** The model these options are for, once made (the viewer steps through its Media tab's rows). */
  readonly model?: () => Pick<ChatInfoModel, "mediaTab"> | undefined
}

/** The Media tab's rows, oldest first (the viewer's order), from the store. */
export const chatInfoMediaRows = (
  model: Pick<ChatInfoModel, "mediaTab"> | undefined,
  peekRow: (key: RowKey) => unknown,
): readonly MessageRow[] => {
  if (!model) return []
  const rows: MessageRow[] = []
  for (const key of model.mediaTab("media").ids.peek()) {
    const row = peekRow(key) as MessageRow | undefined
    if (row?.kind === "message") rows.push(row)
  }
  return rows.reverse()
}

export const chatInfoOptions = (input: ChatInfoPaneInput): ChatInfoModelOptions => {
  const { session, paneId, chatId } = input
  const media = input.media
  const toast = input.toast
  const sources = media?.sources()
  return {
    client: session.client,
    chatId,
    viewerId: session.userId,
    dialog: session.dialogFor(chatId),
    intents: session.intents,
    offline: computed(() => session.health.get().kind === "offline"),
    ...(input.tab ? { tab: input.tab } : {}),
    onTabChange: (next) => void session.workspace.replace({ kind: "chatInfo", chatId, ...(next ? { tab: next } : {}) }, paneId),
    onOpenProfile: (userId) => void session.workspace.openInPane(paneId, { kind: "user", userId }),
    ...(input.copyText ? { copyText: (text: string) => void input.copyText?.(text) } : {}),
    ...(media && sources
      ? {
          media: {
            sources,
            ...(media.openMedia
              ? {
                  onOpenMedia: (open: OpenMediaInput) =>
                    media.openMedia?.(open, () => chatInfoMediaRows(input.model?.(), (key) => session.client.store.peekRow(key)), sources),
                }
              : {}),
            ...(media.download ? { onDownload: media.download } : {}),
            ...(media.openLink ? { onOpenLink: media.openLink } : {}),
          },
        }
      : {}),
    ...(toast
      ? {
          onNotice: (notice) =>
            toast({
              id: "chat-info-members",
              title: notice.title,
              ...(notice.text ? { description: notice.text } : {}),
              tone: notice.kind === "done" ? "neutral" : notice.tone,
            }),
        }
      : {}),
  }
}

