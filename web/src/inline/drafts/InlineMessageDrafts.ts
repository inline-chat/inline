import {
  DbObjectKind,
  messageDraftKey,
  type Db,
  type MessageDraft,
  type MessageDraftPeer,
} from "@inline/client/core"
import type { MessageEntities } from "@inline-chat/protocol/core"

export type InlineMessageDraftsService = {
  load(peer: MessageDraftPeer): Promise<MessageDraft | undefined>
  update(
    peer: MessageDraftPeer,
    text: string,
    entities?: MessageEntities,
  ): Promise<void>
  clear(peer: MessageDraftPeer): Promise<void>
}

const normalizedText = (text: string) =>
  text.replaceAll("\r\n", "\n")

/**
 * Single-owner local draft actor. Operations are serialized so a clear can
 * never be overtaken by an older async save, the failure mode guarded by
 * InlineKit Drafts/Drafts2's intent and revision machinery.
 */
export class InlineMessageDrafts
  implements InlineMessageDraftsService
{
  private operationQueue: Promise<void> = Promise.resolve()
  private readonly loadTasks = new Map<
    string,
    Promise<MessageDraft | undefined>
  >()

  constructor(private readonly db: Db) {}

  load(peer: MessageDraftPeer) {
    return this.operationQueue.then(() => this.loadNow(peer))
  }

  private loadNow(peer: MessageDraftPeer) {
    const id = messageDraftKey(peer)
    const resident = this.db.get(
      this.db.ref(DbObjectKind.MessageDraft, id),
    )
    if (resident) return Promise.resolve(resident)
    const active = this.loadTasks.get(id)
    if (active) return active

    const task = this.db
      .hydrateObjects(DbObjectKind.MessageDraft, [id])
      .then(() =>
        this.db.get(
          this.db.ref(DbObjectKind.MessageDraft, id),
        ),
      )
      .finally(() => {
        if (this.loadTasks.get(id) === task) {
          this.loadTasks.delete(id)
        }
      })
    this.loadTasks.set(id, task)
    return task
  }

  update(
    peer: MessageDraftPeer,
    text: string,
    entities?: MessageEntities,
  ) {
    return this.enqueue(async () => {
      const existing = await this.loadNow(peer)
      const value = normalizedText(text)
      if (value.trim().length === 0) {
        if (existing) {
          await this.db.commit(() => {
            this.db.delete(
              this.db.ref(
                DbObjectKind.MessageDraft,
                messageDraftKey(peer),
              ),
            )
          })
        }
        return
      }

      const next: MessageDraft = {
        kind: DbObjectKind.MessageDraft,
        id: messageDraftKey(peer),
        peerKind: peer.peerKind,
        ...(peer.peerKind === "user"
          ? { peerUserId: peer.peerUserId }
          : { peerThreadId: peer.peerThreadId }),
        text: value,
        entities,
        revision: (existing?.revision ?? 0) + 1,
        updatedAt: Math.floor(Date.now() / 1_000),
      }
      await this.db.commit(() => {
        this.db.replace(next)
      })
    })
  }

  clear(peer: MessageDraftPeer) {
    return this.enqueue(async () => {
      await this.loadNow(peer)
      const ref = this.db.ref(
        DbObjectKind.MessageDraft,
        messageDraftKey(peer),
      )
      if (!this.db.get(ref)) return
      await this.db.commit(() => this.db.delete(ref))
    })
  }

  private enqueue(operation: () => Promise<void>) {
    const queued = this.operationQueue.then(operation)
    this.operationQueue = queued.catch(() => undefined)
    return queued
  }
}
