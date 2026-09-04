import { describe, expect, test } from "bun:test"
import type { CreateChatInput } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { createChatRejectionMetadata } from "@in/server/realtime/message"

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
})
