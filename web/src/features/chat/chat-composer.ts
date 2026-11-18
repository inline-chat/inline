/**
 * The composer for one open chat: `createComposerModel` fed from the chat
 * (send, draft save, the draft restored synchronously when the chat is
 * resident, and a draft that arrives later), registered with the shell for
 * focus and with the unsaved-work tracker for the service worker's reload
 * check and the `pagehide` flush. Framework-free; the pane view creates it
 * with `useModel` per chat, and disposing it flushes the pending draft.
 *
 * Also, when given: `@` suggestions (`suggest`, from `ChatMentions`), the
 * rule-14 check after a send with mentions (`onAccepted`), this user's
 * typing (`reporter`: typing on edits, a stop on send and when the composer
 * empties; owned and disposed here; with attachments also "sending photo"
 * while a sent file uploads), and attachments (`attachments`: paste,
 * drop and the Attach button, sent as media; the model loads on the first
 * file, `chat-attachments.ts`).
 */

import { rowKey, type MessageRow, type UserRow } from "@inline/core-protocol"
import { userShortName } from "@inline/chat-ui"
import type { MessageID } from "@inline/ids"
import type { Dispose, ReadSignal } from "@inline/reactive"
import type { PaneId } from "@inline/view"
import { receivedMessageKey, type ComposerSendRequest } from "@inline/view/features"
import type { SuggestFn } from "../composer/autocomplete"
import { createComposerModel, type ComposerModel, type ComposerModelOptions, type MessagePreview } from "../composer/model"
import type { ComposeReporter } from "../typing/outgoing"
import { attachmentOptions, type LazyAttachments, type SessionAttachments } from "./chat-attachments"
import type { SendKey } from "../settings/preferences"
import { followDraft, type OpenChat } from "./chat-pane-model"

export type ChatComposerDeps = {
  readonly chat: OpenChat
  readonly paneId: PaneId
  readonly safeUrl: (url: string) => string | null
  /** The shell's focus registry (`ShellModel` fits). */
  readonly shell: {
    registerComposer(paneId: PaneId, composer: Pick<ComposerModel, "focus" | "focused">): () => void
  }
  /** Unsaved work (`UnsavedWork` fits). */
  readonly unsaved: { register(source: () => boolean): () => void; onFlush(flush: () => void): () => void }
  /** Escape in an empty composer: focus the message list. */
  readonly focusTimeline: () => void
  /** The send key preference (`preferences.sendKey`), followed live. Default Enter. */
  readonly sendKey?: ReadSignal<SendKey>
  /** Reply and Edit from message actions reach this composer while its pane shows the chat (`MessageActions`). */
  readonly actions?: { registerComposer(chatId: OpenChat["chatId"], composer: ComposerModel): Dispose }
  /** The session's rows, for the reply and edit banners (`store.peekRow`). */
  readonly peekRow?: (key: ReturnType<typeof rowKey>) => unknown
  /** Rows for the active `@` trigger (`ChatMentions.suggest`). */
  readonly suggest?: SuggestFn
  /** A send (not an edit) was accepted: the rule-14 mention check (`ChatMentions.afterSend`). */
  readonly onAccepted?: (request: { readonly entities?: ComposerSendRequest["entities"] }) => void
  /**
   * This user's typing in the chat, and the uploads of media sent from it
   * ("sending photo", `followUploadActivity` over the attachments'
   * `activity`). Owned: disposed with the composer.
   */
  readonly reporter?: Pick<ComposeReporter, "followComposer" | "stopTyping" | "dispose"> & Partial<Pick<ComposeReporter, "beginActivity">>
  /** The chat's attachments and the session's loader. */
  readonly attachments?: { readonly model: LazyAttachments; readonly session: SessionAttachments }
}

/** One line for the reply and edit banners: the text, else what the message holds. */
const previewLine = (row: MessageRow): string => {
  const text = row.text.replace(/\s+/g, " ").trim()
  if (text) return text
  switch (row.media?.kind) {
    case "photo":
      return "Photo"
    case "video":
      return "Video"
    case "document":
      return "File"
    case "voice":
      return "Voice message"
    default:
      return "Message"
  }
}

export type ChatComposer = { readonly model: ComposerModel; dispose(): void }

export const createChatComposer = (deps: ChatComposerDeps): ChatComposer => {
  const { chat } = deps
  const initial = chat.initialDraft()
  const peekRow = deps.peekRow
  const describeMessage = peekRow
    ? (messageId: MessageID): MessagePreview | null => {
        const row = peekRow(receivedMessageKey(chat.chatId, messageId)) as MessageRow | undefined
        if (!row) return null
        const sender = row.out ? undefined : (peekRow(rowKey("user", row.fromId)) as UserRow | undefined)
        return { ...(sender ? { senderName: userShortName(sender) } : {}), text: previewLine(row) }
      }
    : undefined
  // Up in an empty composer edits the viewer's newest editable message (rule 10).
  const onEditLast = (): boolean => {
    const messageId = chat.model.lastEditableMessageId()
    if (messageId === undefined || !peekRow) return false
    const row = peekRow(receivedMessageKey(chat.chatId, messageId)) as MessageRow | undefined
    if (!row) return false
    model.composer.startEdit({ messageId }, { text: row.text, ...(row.entities ? { entities: row.entities } : {}) })
    return true
  }
  const base: ComposerModelOptions = {
    send: (request) => chat.send(request),
    saveDraft: (text, entities, revision) => chat.saveDraft(text, entities, revision),
    safeUrl: deps.safeUrl,
    ...(initial ? { initial } : {}),
    ...(deps.sendKey ? { sendKey: deps.sendKey } : {}),
    ...(describeMessage ? { describeMessage } : {}),
    ...(deps.suggest ? { suggest: deps.suggest } : {}),
    onEditLast,
    onEscapeEmpty: deps.focusTimeline,
  }
  const attachments = deps.attachments
  const withFiles = attachments ? attachmentOptions(attachments.model, attachments.session, base) : base
  const reporter = deps.reporter
  const onAccepted = deps.onAccepted
  const model: ComposerModel = createComposerModel({
    ...withFiles,
    send: async (request) => {
      // The message ends this user's typing at once (the Mac sends the stop with the message).
      if (request.kind === "send") reporter?.stopTyping()
      const outcome = await withFiles.send(request)
      if (outcome.status === "accepted" && request.kind === "send") onAccepted?.(request)
      return outcome
    },
  })
  const disposers: Dispose[] = [
    followDraft(chat, model.composer),
    deps.shell.registerComposer(deps.paneId, model),
    deps.unsaved.register(() => !model.empty.peek()),
    deps.unsaved.onFlush(() => model.composer.flushDraft()),
    ...(deps.actions ? [deps.actions.registerComposer(chat.chatId, model)] : []),
    ...(reporter ? [reporter.followComposer(model.composer.doc), () => reporter.dispose()] : []),
    ...(attachments ? [attachments.session.registerWindow(chat.chatId, chat.model)] : []),
    ...(attachments && reporter?.beginActivity
      ? [attachments.session.followUploads(attachments.model.activity, { beginActivity: (kind) => reporter.beginActivity!(kind) })]
      : []),
  ]
  return {
    model,
    dispose: () => {
      for (const dispose of disposers.splice(0).reverse()) dispose()
      model.dispose()
    },
  }
}
