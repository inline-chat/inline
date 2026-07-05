import { beforeEach, describe, expect, it, vi } from "vitest"
import { Method } from "@inline-chat/protocol/core"
import type { Chat, GetChatsResult, GetSpaceMembersResult, Message, Space, User } from "@inline-chat/protocol/core"
import { createInlineApi } from "./inline-api"

const realtimeSdk = vi.hoisted(() => {
  const client = {
    close: vi.fn(),
    connect: vi.fn(),
    invoke: vi.fn(),
  }
  return {
    client,
    InlineSdkClient: vi.fn(function InlineSdkClient() {
      return client
    }),
  }
})

vi.mock("@inline-chat/realtime-sdk", () => ({
  InlineSdkClient: realtimeSdk.InlineSdkClient,
}))

function space(id: bigint, name: string): Space {
  return { id, name, creator: false, date: 1n }
}

function user(id: bigint, firstName: string, lastName: string, username: string): User {
  return { id, firstName, lastName, username }
}

function spaceChat(id: bigint, title: string, spaceId: bigint, lastMsgId: bigint): Chat {
  return { id, title, spaceId, lastMsgId, date: 1n }
}

function message(id: bigint, chatId: bigint, fromId: bigint, text: string): Message {
  return { id, chatId, fromId, message: text, out: false, date: id }
}

describe("createInlineApi", () => {
  beforeEach(() => {
    realtimeSdk.InlineSdkClient.mockClear()
    realtimeSdk.client.close.mockReset().mockResolvedValue(undefined)
    realtimeSdk.client.connect.mockReset().mockResolvedValue(undefined)
    realtimeSdk.client.invoke.mockReset()
  })

  it("limits people search to users from allowed contexts", async () => {
    const allowedPayloadUser = user(2n, "Ali", "Allowed", "ali")
    const disallowedPayloadUser = user(3n, "Dena", "Secret", "dena")
    const allowedMemberUser = user(4n, "Sam", "Member", "sam")
    const requestedSpaceIds: bigint[] = []
    const getChats: GetChatsResult = {
      dialogs: [],
      chats: [spaceChat(7n, "Allowed", 10n, 100n), spaceChat(8n, "Secret", 20n, 200n)],
      spaces: [space(10n, "Allowed Space"), space(20n, "Secret Space")],
      users: [allowedPayloadUser, disallowedPayloadUser],
      messages: [message(100n, 7n, 2n, "allowed"), message(200n, 8n, 3n, "secret")],
    }
    const getSpaceMembers: GetSpaceMembersResult = {
      members: [{ id: 1n, spaceId: 10n, userId: 4n, date: 1n, canAccessPublicChats: true }],
      users: [allowedMemberUser],
    }

    realtimeSdk.client.invoke.mockImplementation(async (method: Method, input: { getSpaceMembers?: { spaceId: bigint } }) => {
      if (method === Method.GET_CHATS) return { getChats }
      if (method === Method.GET_SPACE_MEMBERS) {
        const spaceId = input.getSpaceMembers?.spaceId
        if (spaceId == null) throw new Error("missing spaceId")
        requestedSpaceIds.push(spaceId)
        return { getSpaceMembers }
      }
      throw new Error(`unexpected method ${method}`)
    })

    const api = createInlineApi({
      baseUrl: "https://api.inline.test",
      token: "test-token",
      allowed: {
        allowedSpaceIds: [10n],
        allowDms: false,
        allowHomeThreads: false,
      },
    })

    const result = await api.searchPeople({ limit: 10 })

    expect(result.items.map((item) => item.userId)).toContain(2n)
    expect(result.items.map((item) => item.userId)).toContain(4n)
    expect(result.items.map((item) => item.userId)).not.toContain(3n)
    expect(requestedSpaceIds).toEqual([10n])
  })
})
