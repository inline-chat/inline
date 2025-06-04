import { describe, test, expect, beforeEach, mock } from "bun:test"
import { UpdateComposeAction_ComposeAction } from "@in/protocol/core"
import { sendComposeAction } from "@in/server/functions/messages.sendComposeAction"
import { setupTestDatabase, testUtils } from "../setup"
import { RealtimeUpdates } from "@in/server/realtime/message"

// Mock RealtimeUpdates.pushToUser to track what updates are sent
const mockPushToUser = mock()
RealtimeUpdates.pushToUser = mockPushToUser

describe("sendComposeAction", () => {
  beforeEach(async () => {
    await setupTestDatabase()
    mockPushToUser.mockClear()
  })

  test("should send typing action to DM participant with correct peer encoding", async () => {
    const user1 = await testUtils.createUser("user1@example.com")
    const user2 = await testUtils.createUser("user2@example.com")

    if (!user1 || !user2) throw new Error("Failed to create users")

    await testUtils.createPrivateChat(user1, user2)

    const inputPeer = {
      type: { oneofKind: "user" as const, user: { userId: BigInt(user2.id) } },
    }

    await sendComposeAction(
      {
        peer: inputPeer,
        action: UpdateComposeAction_ComposeAction.TYPING,
      },
      {
        currentUserId: user1.id,
        currentSessionId: 123,
      },
    )

    // Should send update to user2 only (not sender user1)
    expect(mockPushToUser).toHaveBeenCalledTimes(1)
    expect(mockPushToUser).toHaveBeenCalledWith(user2.id, [
      {
        update: {
          oneofKind: "updateComposeAction",
          updateComposeAction: {
            userId: BigInt(user1.id),
            // For DM, user2 should see user1 as the peer (not user2)
            peerId: { type: { oneofKind: "user", user: { userId: BigInt(user1.id) } } },
            action: UpdateComposeAction_ComposeAction.TYPING,
          },
        },
      },
    ])
  })

  test("should send stop action (NONE) to DM participant", async () => {
    const user1 = await testUtils.createUser("user1@example.com")
    const user2 = await testUtils.createUser("user2@example.com")

    if (!user1 || !user2) throw new Error("Failed to create users")

    await testUtils.createPrivateChat(user1, user2)

    const inputPeer = {
      type: { oneofKind: "user" as const, user: { userId: BigInt(user2.id) } },
    }

    await sendComposeAction(
      {
        peer: inputPeer,
        action: UpdateComposeAction_ComposeAction.NONE,
      },
      {
        currentUserId: user1.id,
        currentSessionId: 123,
      },
    )

    expect(mockPushToUser).toHaveBeenCalledTimes(1)
    expect(mockPushToUser).toHaveBeenCalledWith(user2.id, [
      {
        update: {
          oneofKind: "updateComposeAction",
          updateComposeAction: {
            userId: BigInt(user1.id),
            peerId: { type: { oneofKind: "user", user: { userId: BigInt(user1.id) } } },
            action: UpdateComposeAction_ComposeAction.NONE,
          },
        },
      },
    ])
  })

  test("should send upload action to thread participants with correct peer encoding", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Test Space", [
      "user1@example.com",
      "user2@example.com",
      "user3@example.com",
    ])
    const [user1, user2, user3] = users

    if (!user1 || !user2 || !user3) throw new Error("Failed to create users")

    const chat = await testUtils.createChat(space.id, "Test Thread", "thread")

    if (!chat) throw new Error("Failed to create chat")

    const inputPeer = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } },
    }

    await sendComposeAction(
      {
        peer: inputPeer,
        action: UpdateComposeAction_ComposeAction.UPLOADING_PHOTO,
      },
      {
        currentUserId: user1.id,
        currentSessionId: 123,
      },
    )

    // Should send to user2 and user3 (all space members except sender user1)
    expect(mockPushToUser).toHaveBeenCalledTimes(2)

    // Both recipients should see the same chat peer
    const expectedUpdate = {
      update: {
        oneofKind: "updateComposeAction",
        updateComposeAction: {
          userId: BigInt(user1.id),
          peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
          action: UpdateComposeAction_ComposeAction.UPLOADING_PHOTO,
        },
      },
    }

    expect(mockPushToUser).toHaveBeenCalledWith(user2.id, [expectedUpdate])
    expect(mockPushToUser).toHaveBeenCalledWith(user3.id, [expectedUpdate])
  })

  test("should not send update to sender", async () => {
    const user1 = await testUtils.createUser("user1@example.com")
    const user2 = await testUtils.createUser("user2@example.com")

    if (!user1 || !user2) throw new Error("Failed to create users")

    await testUtils.createPrivateChat(user1, user2)

    const inputPeer = {
      type: { oneofKind: "user" as const, user: { userId: BigInt(user2.id) } },
    }

    await sendComposeAction(
      {
        peer: inputPeer,
        action: UpdateComposeAction_ComposeAction.TYPING,
      },
      {
        currentUserId: user1.id,
        currentSessionId: 123,
      },
    )

    // Verify sender (user1) does not receive an update
    const calls = mockPushToUser.mock.calls
    expect(calls.every((call: any) => call[0] !== user1.id)).toBe(true)
  })

  test("should default to NONE action when no action provided", async () => {
    const user1 = await testUtils.createUser("user1@example.com")
    const user2 = await testUtils.createUser("user2@example.com")

    if (!user1 || !user2) throw new Error("Failed to create users")

    await testUtils.createPrivateChat(user1, user2)

    const inputPeer = {
      type: { oneofKind: "user" as const, user: { userId: BigInt(user2.id) } },
    }

    await sendComposeAction(
      {
        peer: inputPeer,
        // No action provided
      },
      {
        currentUserId: user1.id,
        currentSessionId: 123,
      },
    )

    expect(mockPushToUser).toHaveBeenCalledWith(user2.id, [
      {
        update: {
          oneofKind: "updateComposeAction",
          updateComposeAction: {
            userId: BigInt(user1.id),
            peerId: { type: { oneofKind: "user", user: { userId: BigInt(user1.id) } } },
            action: UpdateComposeAction_ComposeAction.NONE,
          },
        },
      },
    ])
  })
})
