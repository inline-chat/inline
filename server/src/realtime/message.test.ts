import { describe, expect, mock, spyOn, test } from "bun:test"
import { ServerProtocolMessage, type CreateChatInput } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { createChatRejectionMetadata, sendMessageToRealtimeUserWithDelivery } from "@in/server/realtime/message"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"

describe("realtime createChat telemetry", () => {
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
