import { Method } from "@inline-chat/protocol/core"
import { messageId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { readMessages } from "../realtime/transactions/read-messages"
import { CoreHarness } from "./core-harness"
import { chatInputPeer } from "./server-model"

/**
 * Core bugs found by the model-based sync test, each kept as a minimal,
 * deterministic replay of what the random schedules found. A new bug goes
 * in as `it.fails` with its seed and cause; the marker comes off with the
 * fix. KB-1 and KB-2 are fixed (core-hardening, 17 November 2026).
 */

let harness: CoreHarness | undefined

afterEach(async () => {
  await harness?.dispose()
  harness = undefined
})

const chatWithMessages = async (count: number) => {
  harness = CoreHarness.create()
  const { model } = harness
  model.addUser(2n, "Ada")
  model.addChat({ id: 10n, participants: [2n] })
  for (let index = 0; index < count; index += 1) {
    model.postMessage({ chatId: 10n, fromId: 2n, text: `message ${index + 1}` })
  }
  await harness.boot()
  await harness.seedReplicaFromModel()
  await harness.runUntil(() => harness!.connected())
  return harness
}

const dialogState = async (current: CoreHarness) => {
  const replica = await current.snapshot()
  const dialog = replica.dialogs.find((candidate) => candidate.chatId === "10")
  return { readMaxId: dialog?.readMaxId, unreadCount: dialog?.unreadCount }
}

describe("known core bugs", () => {
  /**
   * KB-1. A replayed user-bucket `updateReadMaxId` overwrites a newer read
   * state.
   *
   * `readMessages` answers with an unsequenced `updateReadMaxId`, so the
   * user-bucket cursor stays behind. On the next connection the user bucket
   * replays the journaled record (read boundary 2, unread 0, as of the
   * read). Its page also carries the dialog sidecar with the current state
   * (boundary 2, unread 1), but the record is applied after the sidecar and
   * `updateDialogForPeer` in `realtime/updates/apply-updates.ts` takes its
   * boundary and count unconditionally. The Swift engine ignores a
   * non-advancing `updateReadMaxId` (`InlineProtocol.UpdateReadMaxId.apply`
   * in `InlineKit/RealtimeAPI/Updates.swift`).
   *
   * Seen in random schedules: an own or other-device read, a later incoming
   * message, then any reconnect. Seeds 4, 58 (and 130 of 500 seeds).
   */
  it("KB-1: a replayed read state does not regress the dialog", async () => {
    const current = await chatWithMessages(2)
    await current.settleUntil(
      current.process.client.execute(
        readMessages({ peerId: chatInputPeer(10n), maxId: messageId(2) }),
      ),
    )
    current.model.postMessage({ chatId: 10n, fromId: 2n, text: "after the read" })
    await current.settle()
    expect(await dialogState(current)).toEqual({ readMaxId: "2", unreadCount: 1 })

    await current.heal() // any reconnect replays the user bucket

    expect(current.model.unreadCount(10n)).toBe(1)
    expect(await dialogState(current)).toEqual({ readMaxId: "2", unreadCount: 1 })
  })

  /**
   * KB-2. A message that arrives while its chat is being paged is counted
   * as unread twice.
   *
   * After a reconnect, discovery hints chat 10 at sequence 2 and the sync
   * engine fetches `getUpdates` with `seqEnd` 2. Before the server builds
   * the page, message 3 is posted and pushed live; the client buffers it
   * at sequence 3. The page (through 2) carries the dialog sidecar with the
   * server's current unread count, 3, which already includes message 3.
   * The engine then applies the buffered message 3 as `"realtime"`, and
   * `applyUpdate("newMessage")` increments the count again: 4.
   *
   * Sidecars describe the dialog as of the request, not as of the page's
   * end, so live updates past the page end must not add to the count (or
   * the page must not be bounded below the buffered target). Seed 20.
   * Fixed: the sync engine applies live messages at or below the sidecar
   * chat's `seq` as catch-up, which never adds to the count.
   */
  it("KB-2: a message pushed during catch-up is counted once", async () => {
    const current = await chatWithMessages(1)
    // The socket dies while message 2 is pushed.
    current.intercept((frame) => (frame.kind === "push" ? "drop-and-disconnect" : "deliver"))
    current.model.postMessage({ chatId: 10n, fromId: 2n, text: "lost with the socket" })
    current.intercept(() => "deliver")
    // Message 3 arrives while the server is building the page for chat 10.
    let posted = false
    current.process.endpoint.beforeRpc = ({ method, input }) => {
      if (
        !posted &&
        method === Method.GET_UPDATES &&
        input.oneofKind === "getUpdates" &&
        input.getUpdates.bucket?.type.oneofKind === "chat"
      ) {
        posted = true
        current.model.postMessage({ chatId: 10n, fromId: 2n, text: "during catch-up" })
      }
    }
    await current.heal({ reconnect: false })

    expect(posted).toBe(true)
    expect(current.model.unreadCount(10n)).toBe(3)
    expect((await dialogState(current)).unreadCount).toBe(3)
  })
})
