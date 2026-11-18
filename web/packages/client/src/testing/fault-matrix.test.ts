import { Method } from "@inline-chat/protocol/core"
import { chatId } from "@inline/ids"
import { expect } from "vitest"
import { MessageSendingStatus } from "../database/models"
import { sendMessage } from "../realtime/transactions/send-message"
import { describeFaultMatrix, type FaultScenario } from "./fault-matrix"
import { compareReplica } from "./model-sync/compare"
import { chatInputPeer } from "./server-model"

/**
 * The worked example: sending a text message, under every fault in the
 * matrix. Each case boots a real core against the server model, injects the
 * fault, restarts the core if the fault killed it, heals and checks that
 * the message exists exactly once (or, when it was never durably accepted,
 * nowhere), with no stuck optimistic row and an empty outbox.
 */

const TEXT = "Send under faults — שלום — 完成"

const sendTextScenario: FaultScenario = {
  name: "send text",
  setup: ({ harness }) => {
    harness.model.addUser(2n, "Ada")
    harness.model.addChat({ id: 10n, participants: [2n] })
    harness.model.postMessage({ chatId: 10n, fromId: 2n, text: "earlier" })
  },
  act: ({ harness }) => {
    void harness.process.client
      .execute(sendMessage({ chatId: chatId(10), peerId: chatInputPeer(10n), text: TEXT }))
      .catch(() => undefined)
  },
  verify: async ({ harness }, fault) => {
    const { model } = harness
    const onServer = model.chatState(10n).messages.filter(
      (message) => message.text === TEXT && message.fromId === model.selfUserId,
    )

    if (fault.outcome === "never-sent") {
      expect(onServer).toHaveLength(0)
      expect(model.rpcLog.some((entry) => entry.method === Method.SEND_MESSAGE)).toBe(false)
      expect(harness.process.client.connection.state).toBe("stopped")
      expect(harness.process.auth.isLoggedIn()).toBe(false)
      return
    }

    expect(onServer).toHaveLength(fault.outcome === "applied-once" ? 1 : 0)
    const replica = await harness.snapshot()
    const rows = replica.messages.filter((message) => message.message === TEXT)
    if (fault.outcome === "applied-once") {
      expect(rows).toHaveLength(1)
      expect(BigInt(rows[0]!.messageId)).toBe(onServer[0]!.id)
      expect(rows[0]!.status).not.toBe(MessageSendingStatus.Sending)
      expect(rows[0]!.status).not.toBe(MessageSendingStatus.Failed)
    } else {
      expect(rows).toHaveLength(0)
    }
    expect(replica.pendingTransactions).toEqual([])
    const divergences = compareReplica(model, replica, { unverifiableReactions: new Set() })
    expect(divergences.filter((divergence) => !divergence.knownBug)).toEqual([])
  },
}

describeFaultMatrix(sendTextScenario)
