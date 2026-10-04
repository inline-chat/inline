import { describe, expect, mock, spyOn, test } from "bun:test"
import { ServerProtocolMessage, UpdateComposeAction_ComposeAction as ComposeAction, type CreateChatInput, type Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { createChatRejectionMetadata, RealtimeUpdates, sendMessageToRealtimeUserWithDelivery } from "@in/server/realtime/message"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"

describe("realtime createChat telemetry", () => {
  test("projects working per socket across mixed V2/V3 clients without mutating the shared update", async () => {
    const userId = 82_004
    const membershipReader = connectionManager as unknown as { getUserSpaceIds(userId: number): Promise<number[]> }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const sockets = [
      { id: "working-old-v2", version: ConnVersion.REALTIME_V1, supportsWorking: undefined },
      { id: "working-new-v3", version: ConnVersion.REALTIME_V3, supportsWorking: true },
      { id: "working-old-v3", version: ConnVersion.REALTIME_V3, supportsWorking: false },
      { id: "working-new-v2", version: ConnVersion.REALTIME_V1, supportsWorking: true },
    ].map((entry, index) => ({ ...entry, sessionId: 91_010 + index, sent: [] as ServerProtocolMessage[] }))
    const updates: Update[] = [ComposeAction.WORKING, ComposeAction.TYPING, ComposeAction.NONE].map((action) => ({
      update: { oneofKind: "updateComposeAction", updateComposeAction: {
        action, userId: 50n, peerId: { type: { oneofKind: "chat", chat: { chatId: 70n } } },
      } },
    }))
    const before = structuredClone(updates)
    const actions = (frames: ServerProtocolMessage[]) => frames.flatMap((frame) => {
      if (frame.body.oneofKind !== "message" || frame.body.message.payload.oneofKind !== "update") return []
      return frame.body.message.payload.update.updates.map(({ update }) =>
        update.oneofKind === "updateComposeAction" ? update.updateComposeAction.action : undefined)
    })
    try {
      for (const socket of sockets) {
        connectionManager.addConnection({ id: socket.id, close() {}, subscribe() {}, raw: {
          sendBinary(bytes: Uint8Array) { socket.sent.push(ServerProtocolMessage.fromBinary(bytes)); return bytes.length },
        } } as never, socket.version)
        connectionManager.authenticateConnection(socket.id, userId, socket.sessionId)
        if (socket.supportsWorking !== undefined) {
          connectionManager.setSupportsWorking(socket.id, userId, socket.sessionId, socket.supportsWorking)
        }
      }
      // Both local publishers and the transient broker subscriber use this fanout.
      expect(await RealtimeUpdates.pushToUserWithDelivery(userId, updates)).toBe(4)
      for (const socket of sockets) {
        expect(actions(socket.sent)).toEqual([
          socket.supportsWorking ? ComposeAction.WORKING : ComposeAction.TYPING, ComposeAction.TYPING, ComposeAction.NONE,
        ])
      }
      expect(updates).toEqual(before)

      // A reconnect has its own capability and must advertise again, even for
      // the same account session; stale/wrong identity updates are ignored.
      const old = sockets[0]!
      connectionManager.setSupportsWorking(old.id, userId + 1, old.sessionId, true)
      expect(connectionManager.getConnection(old.id)?.supportsWorking).toBeUndefined()
      const modern = sockets[1]!
      connectionManager.removeConnection(modern.id)
      connectionManager.addConnection({ id: modern.id, close() {}, subscribe() {} } as never, modern.version)
      connectionManager.authenticateConnection(modern.id, userId, modern.sessionId)
      expect(connectionManager.getConnection(modern.id)?.supportsWorking).toBeUndefined()
    } finally {
      for (const socket of sockets) connectionManager.removeConnection(socket.id)
      await connectionManager.waitForBackgroundWork()
      readMemberships.mockRestore()
    }
  })

  test("records only the rejection class and request shape", () => {
    const input: CreateChatInput = {
      title: "Private incident title",
      description: "Private incident description",
      spaceId: 8_765_432_101n,
      isPublic: false,
      participants: [{ userId: 8_765_432_102n }],
      reservedChatId: 8_765_432_103n,
      agentContext: {
        botUserId: 8_765_432_104n,
        agentId: 8_765_432_105n,
        configuration: {
          projectId: "private-project",
          modelId: "private-model",
          reasoningEffortId: "private-reasoning",
        },
      },
    }

    const metadata = createChatRejectionMetadata(input, RealtimeRpcError.BadRequest())

    expect(metadata).toEqual({
      event: "realtime.create_chat.rejected",
      method: "CREATE_CHAT",
      errorCodeName: "BAD_REQUEST",
      errorCodeNumber: 400,
      hasReservedChatId: true,
      destination: "space",
      visibility: "private",
      participantCount: 1,
      hasAgentContext: true,
      hasAgentId: true,
      hasConfiguration: true,
      hasProject: true,
      hasModel: true,
      hasReasoning: true,
    })
    const serialized = JSON.stringify(metadata)
    expect(serialized).not.toContain("Private incident")
    expect(serialized).not.toContain("87654321")
    expect(serialized).not.toContain("private-project")
    expect(serialized).not.toContain("private-model")
    expect(serialized).not.toContain("private-reasoning")
  })

  test("delivers an authenticated socket update without a session query", async () => {
    const connectionId = "delivery-no-query"
    const sent: ServerProtocolMessage[] = []
    const socket = {
      id: connectionId,
      close: mock(),
      subscribe: mock(),
      raw: {
        sendBinary(bytes: Uint8Array): number {
          sent.push(ServerProtocolMessage.fromBinary(bytes))
          return bytes.length
        },
      },
    }
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const select = spyOn(db, "select")

    connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, 82_001, 91_001)
    await Promise.resolve()
    select.mockClear()
    try {
      const accepted = await sendMessageToRealtimeUserWithDelivery(82_001, {
        oneofKind: "update",
        update: { updates: [] },
      })

      expect(accepted).toBe(1)
      expect(select).not.toHaveBeenCalled()
      expect(sent).toHaveLength(1)
      expect(sent[0]?.body.oneofKind).toBe("message")
    } finally {
      connectionManager.removeConnection(connectionId)
      readMemberships.mockRestore()
      select.mockRestore()
    }
  })

  test("drops a socket whose transport rejects an outbound frame", async () => {
    const connectionId = "delivery-rejected-transport"
    const socket = {
      id: connectionId,
      close: mock(),
      subscribe: mock(),
      raw: { sendBinary: () => 0 },
    }
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, 82_002, 91_002)
    try {
      await expect(sendMessageToRealtimeUserWithDelivery(82_002, {
        oneofKind: "update",
        update: { updates: [] },
      })).resolves.toBe(0)
      expect(socket.close).toHaveBeenCalledWith()
      expect(connectionManager.getConnection(connectionId)).toBeUndefined()
    } finally {
      connectionManager.removeConnection(connectionId)
      readMemberships.mockRestore()
    }
  })

  test("keeps a socket when Bun accepts a frame under backpressure", async () => {
    const connectionId = "delivery-buffered-transport"
    const socket = {
      id: connectionId,
      close: mock(),
      subscribe: mock(),
      raw: { sendBinary: () => -1 },
    }
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
    connectionManager.authenticateConnection(connectionId, 82_003, 91_003)
    try {
      await expect(sendMessageToRealtimeUserWithDelivery(82_003, {
        oneofKind: "update",
        update: { updates: [] },
      })).resolves.toBe(1)
      expect(socket.close).not.toHaveBeenCalled()
      expect(connectionManager.getConnection(connectionId)).toBeDefined()
    } finally {
      connectionManager.removeConnection(connectionId)
      readMemberships.mockRestore()
    }
  })
})
