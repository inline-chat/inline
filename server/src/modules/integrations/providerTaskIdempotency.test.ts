import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { externalTasks } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { encrypt } from "@in/server/modules/encryption/encryption"
import {
  findExistingProviderTask,
  isProviderTaskIdempotencyConflict,
  linearTaskReplayResponse,
  notionTaskReplayResponse,
} from "./providerTaskIdempotency"

describe("provider task idempotency", () => {
  setupTestLifecycle()

  test("replays the task for the same provider, source message, and connector space", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers(
      "Task idempotency",
      ["task-idempotency@example.com"],
    )
    const user = users[0]
    if (!user) throw new Error("user not created")
    const { msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user,
      isPublic: false,
    })

    const [created] = await db.insert(externalTasks).values({
      application: "notion",
      taskId: "page-1",
      status: "todo",
      assignedUserId: BigInt(user.id),
      connectorSpaceId: space.id,
      sourceMessageId: msg.globalId,
      url: "https://notion.so/page-1",
    }).returning()

    const replay = await findExistingProviderTask({
      application: "notion",
      assignedUserId: BigInt(user.id),
      sourceMessageId: msg.globalId,
      connectorSpaceId: space.id,
    })

    expect(replay?.id).toBe(created?.id)
    expect(replay?.url).toBe("https://notion.so/page-1")
  })

  test("the database rejects a concurrent duplicate receipt", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers(
      "Task idempotency race",
      ["task-idempotency-race@example.com"],
    )
    const user = users[0]
    if (!user) throw new Error("user not created")
    const { msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user,
      isPublic: false,
    })
    const receipt = {
      application: "linear",
      taskId: "issue-1",
      status: "todo" as const,
      assignedUserId: BigInt(user.id),
      connectorSpaceId: space.id,
      sourceMessageId: msg.globalId,
      url: "https://linear.app/issue-1",
    }

    await db.insert(externalTasks).values(receipt)
    const error = await db.insert(externalTasks).values({
      ...receipt,
      taskId: "issue-2",
    }).then(() => undefined, (cause) => cause)

    expect(isProviderTaskIdempotencyConflict(error)).toBe(true)
  })

  test("does not conflate providers, connector spaces, or users", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers(
      "Task idempotency scopes",
      [
        "task-idempotency-scopes@example.com",
        "task-idempotency-other-user@example.com",
      ],
    )
    const otherSpace = await testUtils.createSpace("Other connector space")
    const user = users[0]
    const otherUser = users[1]
    if (!user || !otherUser || !otherSpace) throw new Error("fixture not created")
    const { msg } = await testUtils.createThreadWithDialogAndMessage({
      spaceId: space.id,
      user,
      isPublic: false,
    })

    await db.insert(externalTasks).values([
      {
        application: "notion",
        taskId: "notion-page",
        status: "todo",
        assignedUserId: BigInt(user.id),
        connectorSpaceId: space.id,
        sourceMessageId: msg.globalId,
      },
      {
        application: "linear",
        taskId: "linear-issue",
        status: "todo",
        assignedUserId: BigInt(user.id),
        connectorSpaceId: space.id,
        sourceMessageId: msg.globalId,
      },
      {
        application: "notion",
        taskId: "other-space-page",
        status: "todo",
        assignedUserId: BigInt(user.id),
        connectorSpaceId: otherSpace.id,
        sourceMessageId: msg.globalId,
      },
      {
        application: "notion",
        taskId: "other-user-page",
        status: "todo",
        assignedUserId: BigInt(otherUser.id),
        connectorSpaceId: space.id,
        sourceMessageId: msg.globalId,
      },
    ])

    expect((await findExistingProviderTask({
      application: "notion",
      assignedUserId: BigInt(user.id),
      sourceMessageId: msg.globalId,
      connectorSpaceId: space.id,
    }))?.taskId).toBe("notion-page")
    expect((await findExistingProviderTask({
      application: "linear",
      assignedUserId: BigInt(user.id),
      sourceMessageId: msg.globalId,
      connectorSpaceId: space.id,
    }))?.taskId).toBe("linear-issue")
    expect((await findExistingProviderTask({
      application: "notion",
      assignedUserId: BigInt(user.id),
      sourceMessageId: msg.globalId,
      connectorSpaceId: otherSpace.id,
    }))?.taskId).toBe("other-space-page")
    expect((await findExistingProviderTask({
      application: "notion",
      assignedUserId: BigInt(otherUser.id),
      sourceMessageId: msg.globalId,
      connectorSpaceId: space.id,
    }))?.taskId).toBe("other-user-page")
  })

  test("reconstructs provider responses from the durable receipt", async () => {
    const encryptedTitle = encrypt("Follow up with design")
    const receipt = {
      id: 1,
      application: "notion",
      taskId: "page-1",
      status: "todo" as const,
      assignedUserId: 1n,
      connectorSpaceId: 1,
      sourceMessageId: 1n,
      number: null,
      url: "https://notion.so/page-1",
      title: encryptedTitle.encrypted,
      titleIv: encryptedTitle.iv,
      titleTag: encryptedTitle.authTag,
      date: new Date(),
    }

    expect(notionTaskReplayResponse(receipt)).toEqual({
      url: "https://notion.so/page-1",
      taskTitle: "Follow up with design",
    })
    expect(linearTaskReplayResponse({
      ...receipt,
      application: "linear",
      url: "https://linear.app/issue/ENG-1",
    })).toEqual({ link: "https://linear.app/issue/ENG-1" })
  })

  test("does not replay an incomplete receipt", () => {
    expect(notionTaskReplayResponse({
      id: 1,
      application: "notion",
      taskId: "page-1",
      status: "todo",
      assignedUserId: 1n,
      connectorSpaceId: 1,
      sourceMessageId: 1n,
      number: null,
      url: null,
      title: null,
      titleIv: null,
      titleTag: null,
      date: new Date(),
    })).toBeUndefined()
  })
})
