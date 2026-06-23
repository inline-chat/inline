import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { RichDirection, RpcError_Code, type InputPeer, type RichMessage } from "@inline-chat/protocol/core"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { sendRichMessageDraft } from "@in/server/realtime/handlers/messages.sendRichMessageDraft"
import type { HandlerContext } from "@in/server/realtime/types"
import { setupTestLifecycle, testUtils, defaultTestContext } from "../setup"

describe("messages.sendRichMessageDraft", () => {
  setupTestLifecycle()

  const originalPushToUser = RealtimeUpdates.pushToUser
  let pushedUpdates: Array<{ userId: number; updates: Parameters<typeof RealtimeUpdates.pushToUser>[1] }> = []

  beforeEach(() => {
    pushedUpdates = []
    RealtimeUpdates.pushToUser = ((userId, updates) => {
      pushedUpdates.push({ userId, updates })
    }) as typeof RealtimeUpdates.pushToUser
  })

  afterEach(() => {
    RealtimeUpdates.pushToUser = originalPushToUser
  })

  test("publishes a transient thinking draft update through the realtime rpc", async () => {
    const { user, peerId } = await makeUserThread("rich-draft-rpc-thinking-user@example.com")
    const startSeconds = Math.round(Date.now() / 1000)

    await sendRichMessageDraft(
      {
        peerId,
        draftId: "  rpc-rich-draft-thinking  ",
        messageId: 101n,
        richText: richTextWithThinking(),
        ttlSeconds: 86_400,
      },
      handlerContext(user.id),
    )

    expect(pushedUpdates).toHaveLength(1)
    expect(pushedUpdates[0]?.userId).toBe(user.id)
    const draft = firstDraft()
    expect(draft.draftId).toBe("rpc-rich-draft-thinking")
    expect(draft.senderUserId).toBe(BigInt(user.id))
    expect(draft.messageId).toBe(101n)
    expect(draft.clear).toBe(false)
    expect(draft.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph"])
    expect(Number(draft.expiresAt)).toBeGreaterThan(startSeconds)
    expect(Number(draft.expiresAt)).toBeLessThanOrEqual(startSeconds + 125)
  })

  test("publishes a clear update without rich text through the realtime rpc", async () => {
    const { user, peerId } = await makeUserThread("rich-draft-rpc-clear-user@example.com")

    await sendRichMessageDraft(
      {
        peerId,
        draftId: " rpc-rich-draft-clear ",
        messageId: 202n,
        clear: true,
      },
      handlerContext(user.id),
    )

    expect(pushedUpdates).toHaveLength(1)
    const draft = firstDraft()
    expect(draft.draftId).toBe("rpc-rich-draft-clear")
    expect(draft.messageId).toBe(202n)
    expect(draft.clear).toBe(true)
    expect(draft.richText).toBeUndefined()
  })

  test("rejects blank draft ids before publishing", async () => {
    const { user, peerId } = await makeUserThread("rich-draft-rpc-blank-user@example.com")

    await expect(
      sendRichMessageDraft(
        {
          peerId,
          draftId: " \t\n ",
          clear: true,
        },
        handlerContext(user.id),
      ),
    ).rejects.toMatchObject({
      code: RpcError_Code.BAD_REQUEST,
      codeNumber: 400,
    })
    expect(pushedUpdates).toHaveLength(0)
  })

  test("maps oversized draft ids to bad request before publishing", async () => {
    const { user, peerId } = await makeUserThread("rich-draft-rpc-oversized-id-user@example.com")

    await expect(
      sendRichMessageDraft(
        {
          peerId,
          draftId: "x".repeat(257),
          clear: true,
        },
        handlerContext(user.id),
      ),
    ).rejects.toMatchObject({
      code: RpcError_Code.BAD_REQUEST,
      codeNumber: 400,
    })
    expect(pushedUpdates).toHaveLength(0)
  })

  test("maps unresolved public draft media to a bad request rpc error", async () => {
    const { user, peerId } = await makeUserThread("rich-draft-rpc-public-media-user@example.com")

    await expect(
      sendRichMessageDraft(
        {
          peerId,
          draftId: "rpc-rich-draft-public-media",
          richText: richTextWithPublicPhoto(),
        },
        handlerContext(user.id),
      ),
    ).rejects.toMatchObject({
      code: RpcError_Code.BAD_REQUEST,
      codeNumber: 400,
    })
    expect(pushedUpdates).toHaveLength(0)
  })

  function firstDraft() {
    const update = pushedUpdates[0]?.updates[0]
    expect(update?.update.oneofKind).toBe("richMessageDraft")
    if (!update || update.update.oneofKind !== "richMessageDraft") {
      throw new Error("Expected richMessageDraft update")
    }
    return update.update.richMessageDraft
  }
})

async function makeUserThread(email: string) {
  const user = await testUtils.createUser(email)
  const chat = await testUtils.createChat(null, "Rich Draft RPC", "thread", false, user.id)
  if (!chat) {
    throw new Error("Failed to create test chat")
  }
  await testUtils.addParticipant(chat.id, user.id)

  const peerId: InputPeer = {
    type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
  }

  return { user, chat, peerId }
}

function handlerContext(userId: number): HandlerContext {
  return {
    userId,
    sessionId: defaultTestContext.sessionId,
    connectionId: "rich-draft-rpc-test",
    sendRaw: () => {},
    sendRpcReply: () => {},
  }
}

function richTextWithPublicPhoto(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "[Image: draft]",
    blocks: [
      {
        blockId: "draft-photo",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: "draft",
              media: { oneofKind: "publicUrl", publicUrl: "https://example.com/draft.png" },
            },
            caption: [],
          },
        },
      },
    ],
  }
}

function richTextWithThinking(): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: "",
    blocks: [
      {
        blockId: "thinking",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "thinking",
          thinking: {
            initiallyCollapsed: true,
            blocks: [
              {
                blockId: "thinking-visible",
                direction: RichDirection.DIRECTION_AUTO,
                block: {
                  oneofKind: "paragraph",
                  paragraph: {
                    text: [{ text: "private reasoning", styles: [], children: [] }],
                  },
                },
              },
            ],
          },
        },
      },
      {
        blockId: "answer",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "paragraph",
          paragraph: {
            text: [{ text: "visible answer", styles: [], children: [] }],
          },
        },
      },
    ],
  }
}
