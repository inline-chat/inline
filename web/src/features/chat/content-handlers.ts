/**
 * What the message content calls in the chat pane (`ContentHandlers`) and
 * how it names people (`ContentNames`). Part of the content chunk
 * (`content-chunk.tsx`): the content views are the only callers, so none
 * of this is in the shell. `ChatContent` creates both once per pane with
 * its options; they act on whichever chat the pane shows when they fire.
 *
 * - Bot buttons (`onAction`): a callback goes to the session's
 *   `invokeAction` (the button spins until the final outcome; refusals and
 *   the bot's answer are the session's notices); copy, open link, open URL,
 *   compose and unavailable act here. A button with a confirm step asks
 *   first in the shell's confirmation alert.
 * - Forms (`onSubmitForm`): the chat model's `submitForm`; resolves when
 *   confirmed (the bot's answer as a toast), rejects on a refusal (the form
 *   returns to editing, the notice as a toast). An uncertain outcome
 *   resolves with a "Not confirmed yet" toast: trying again could submit
 *   twice.
 * - Photos and videos (`onOpenMedia`): the media viewer, over the media
 *   layer the content uses.
 */

import { unavailableActionText, userDisplayName, userShortName, type ButtonModel, type SafeLink } from "@inline/chat-ui"
import { rowKey, type ActionAnswer, type ChatRow, type MediaContent, type MessageRowId, type UserRow } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import type { Destination } from "@inline/view"
import type { ActionNotice } from "@inline/view/features"
import type { ContentHandlers, ContentNames, MediaSources, OpenMediaInput } from "../content"
// The files themselves, not the content index: the content chunk's boundary stays where it is.
import { buttonDisclosure, disclosureText } from "../content/buttons"
import { downloadFailedText, downloadMessageFile } from "./download"
import type { ChatContentOptions, ContentToast } from "./chat-content"

/** A refusal or an uncertain outcome as a toast (the session's words and tone). */
export const noticeToast = (notice: ActionNotice): ContentToast => ({
  title: notice.title,
  description: notice.text,
  tone: notice.tone,
})

/** A bot's answer as a toast. */
export const answerToast = (answer: ActionAnswer): ContentToast =>
  answer.kind === "alert" && answer.title
    ? { title: answer.title, description: answer.text, tone: "neutral" }
    : { title: answer.text, tone: "neutral" }

/** The form refused (the form shows its own retry line; the toast says why). */
export class FormRefused extends Error {}

/** How people and chats are named in message content, from the session's rows. */
export const contentNames = (peekRow: ChatContentOptions["peekRow"]): ContentNames => {
  const user = (id: UserID) => peekRow(rowKey("user", id)) as UserRow | undefined
  return {
    user: (id) => {
      const row = user(id)
      if (!row) return undefined
      return { name: userDisplayName(row), seed: id, ...(row.photoUrl ? { photoUrl: row.photoUrl } : {}) }
    },
    forwardTitle: (forward) => {
      const peer = forward.fromPeer
      if (peer?.kind === "chat") {
        const chat = peekRow(rowKey("chat", peer.chatId)) as ChatRow | undefined
        if (chat?.title) return chat.title
      }
      const fromId = forward.fromUserId ?? (peer?.kind === "user" ? peer.userId : undefined)
      const from = fromId !== undefined ? user(fromId) : undefined
      return from ? userShortName(from) : undefined
    },
    botName: (id) => {
      const row = user(id)
      return row ? userShortName(row) : undefined
    },
  }
}

/** The content's handlers for one pane. `currentSources`: the media layer the content uses (for the viewer). */
export const contentHandlers = (options: ChatContentOptions, currentSources: () => MediaSources | undefined): ContentHandlers => {
  const openLink = (link: SafeLink): void => {
    if (link.kind === "app") {
      const destination = options.parseAppLink(link.href)
      if (destination) options.open(destination)
      return
    }
    options.openExternal(link.href)
  }

  /** What a button does, without its confirm step. A callback returns its final outcome as a promise (the spinner). */
  const perform = (rowId: MessageRowId, button: ButtonModel): Promise<void> | void => {
    const behavior = button.behavior
    switch (behavior.kind) {
      case "callback": {
        const handle = options.invokeAction?.(rowId, button.actionId)
        if (!handle) {
          options.toast?.({ title: unavailableActionText, tone: "neutral" })
          return
        }
        return handle.outcome.then(() => undefined)
      }
      case "copy": {
        options.copyText(behavior.text)
        // What was copied, in the app's words: the bot's label may say anything (security.md, "Bot buttons").
        const preview = copiedPreview(button)
        options.toast?.({ title: "Copied", ...(preview ? { description: preview } : {}), tone: "neutral" })
        return
      }
      case "openUrl":
        openLink(behavior.link)
        return
      case "openLink":
        options.open(
          behavior.peer.kind === "chat"
            ? behavior.messageId !== undefined
              ? { kind: "message", chatId: behavior.peer.chatId, messageId: behavior.messageId }
              : { kind: "chat", chatId: behavior.peer.chatId }
            : { kind: "user", userId: behavior.peer.userId },
        )
        return
      case "compose":
        options.compose?.(behavior.text)
        return
      case "unavailable":
        options.toast?.({ title: unavailableActionText, description: behavior.reason, tone: "neutral" })
        return
    }
  }

  return {
    onAppLink: (link, event) => {
      const destination = options.parseAppLink(link.href)
      if (!destination) return
      event.preventDefault()
      options.open(destination)
    },
    onOpenReplies: ({ chatId }) => {
      const parentChatId = options.currentChatId()
      const destination: Destination =
        parentChatId !== undefined ? { kind: "thread", parentChatId, threadId: chatId } : { kind: "chat", chatId }
      options.open(destination, options.threadsInSidePane() ? "otherPane" : "here")
    },
    onOpenPeer: (peer, messageId) => {
      if (peer.kind === "chat") {
        options.open(
          messageId !== undefined ? { kind: "message", chatId: peer.chatId, messageId } : { kind: "chat", chatId: peer.chatId },
        )
      } else {
        options.open({ kind: "user", userId: peer.userId })
      }
    },
    onCopyText: (text) => options.copyText(text),
    onAction: ({ rowId, button }) => {
      const confirm = button.confirm
      if (!confirm || !options.confirm) return perform(rowId, button)
      const ask = options.confirm
      // Under the bot's own words: where the button really goes, or what it copies.
      const detail = disclosureText(buttonDisclosure(button))
      return new Promise<void>((resolve) => {
        ask({
          title: confirm.title,
          ...(confirm.text ? { description: confirm.text } : {}),
          ...(detail ? { detail } : {}),
          confirmLabel: confirm.confirmLabel,
          destructive: false,
          run: () => {
            const result = perform(rowId, button)
            if (result) result.then(resolve, resolve)
            else resolve()
          },
          cancel: resolve,
        })
      })
    },
    onSubmitForm: async ({ rowId, formId, values }) => {
      const handle = options.submitForm?.(rowId, formId, values)
      if (!handle) throw new FormRefused(unavailableActionText)
      const first = await handle
      if (first.status === "rejected") {
        options.toast?.(noticeToast(first.notice))
        throw new FormRefused(first.notice.title)
      }
      const outcome = await handle.outcome
      if (outcome.status === "confirmed") {
        if (outcome.answer) options.toast?.(answerToast(outcome.answer))
        return
      }
      options.toast?.(noticeToast(outcome.notice))
      if (outcome.status === "rejected") throw new FormRefused(outcome.notice.title)
    },
    ...(options.openMedia
      ? {
          onOpenMedia: (input: OpenMediaInput) => {
            const sources = currentSources()
            if (sources) options.openMedia?.(input, sources)
          },
        }
      : {}),
    ...(options.compose ? { onCompose: options.compose } : {}),
    ...(options.files
      ? {
          onDownload: ({ rowId, media }: { readonly rowId: MessageRowId; readonly media: MediaContent }) =>
            void downloadRowFile(options, rowId, media),
        }
      : {}),
  }
}

/** A document's Download (`download.ts`), with the pane's files and toasts. */
export const downloadRowFile = (options: Pick<ChatContentOptions, "files" | "toast">, rowId: MessageRowId, media: MediaContent): Promise<string | undefined> =>
  options.files ? downloadMessageFile({ ...options.files, ...(options.toast ? { toast: options.toast } : {}) }, rowId, media) : Promise.resolve(undefined)

export { downloadFailedText }

/** A copy button's toast line: the start of the copied text, and its length when the start is not all of it. */
export const copiedPreview = (button: ButtonModel): string | undefined => {
  const disclosure = buttonDisclosure(button)
  if (disclosure.copyPreview === undefined) return undefined
  const shown = Array.from(disclosure.copyPreview).length
  const partial = disclosure.copyLength !== undefined && disclosure.copyLength > shown
  return `“${disclosure.copyPreview}”${partial ? ` (${disclosure.copyLength} characters)` : ""}`
}
