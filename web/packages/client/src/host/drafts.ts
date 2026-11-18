/**
 * Drafts: a small API over the existing `MessageDraft` model and table
 * (database/models.ts). Drafts are local-only, keyed by peer like InlineKit
 * Drafts2: a DM's draft lives under its user, any other chat's under the chat.
 * Built on `Db`'s public methods; `database/` is unchanged.
 */
import type { Entity } from "@inline/core-protocol"
import type { ChatID } from "@inline/ids"
import type { Db } from "../database"
import {
  DbObjectKind,
  messageDraftKey,
  type MessageDraft,
  type MessageDraftPeer,
} from "../database/models"
import { entitiesToProtocol } from "../queries/rows"
import type { ReplicaView } from "../queries/view"
import { peerUserForChat } from "./peers"

export const draftPeerForChat = (db: Db, chatId: ChatID): MessageDraftPeer => {
  const peerUserId = peerUserForChat(db, chatId)
  return peerUserId
    ? { peerKind: "user", peerUserId }
    : { peerKind: "chat", peerThreadId: chatId }
}

/** The draft for a chat in the committed view, and its key. */
export const draftFor = (
  view: ReplicaView,
  chatId: ChatID,
): { key: string; draft: MessageDraft | undefined } => {
  const peerUserId =
    view.get(DbObjectKind.Chat, chatId)?.peerUserId ??
    view.all(DbObjectKind.Dialog).find((dialog) => dialog.chatId === chatId)?.peerUserId
  const key = messageDraftKey(
    peerUserId ? { peerKind: "user", peerUserId } : { peerKind: "chat", peerThreadId: chatId },
  )
  return { key, draft: view.get(DbObjectKind.MessageDraft, key) }
}

export type DraftInput = {
  chatId: ChatID
  text: string
  entities?: Entity[]
  revision: number
}

/**
 * Durably save a draft. Resolves after the commit, so a composer may clear
 * only once this resolves. An empty draft deletes the stored one. A save with
 * a lower revision than the stored draft is a no-op: a newer one already won.
 */
export const saveDraft = (db: Db, input: DraftInput, now: number): Promise<void> =>
  db.commit(() => {
    const peer = draftPeerForChat(db, input.chatId)
    const ref = db.ref(DbObjectKind.MessageDraft, messageDraftKey(peer))
    const existing = db.get(ref)
    if (existing && existing.revision > input.revision) return
    const entities = entitiesToProtocol(input.entities)
    if (input.text.trim().length === 0 && !entities) {
      if (existing) db.delete(ref)
      return
    }
    db.replace({
      kind: DbObjectKind.MessageDraft,
      id: ref.id,
      ...peer,
      text: input.text,
      ...(entities ? { entities } : {}),
      revision: input.revision,
      updatedAt: now,
    })
  })

/**
 * Inside a commit: delete the chat's draft when its revision is at most
 * `revision` (the draft a send consumed). A draft saved after the send has
 * a higher revision and stays. Returns whether it deleted one.
 */
export const consumeDraft = (db: Db, chatId: ChatID, revision: number): boolean => {
  const ref = db.ref(DbObjectKind.MessageDraft, messageDraftKey(draftPeerForChat(db, chatId)))
  const existing = db.get(ref)
  if (!existing || existing.revision > revision) return false
  db.delete(ref)
  return true
}
