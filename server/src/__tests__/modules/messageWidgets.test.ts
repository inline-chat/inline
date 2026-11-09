import { beforeEach, describe, expect, test } from "bun:test"
import { RpcError_Code, type InputPeer } from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel } from "@in/server/db/models/updates"
import { updates, users } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { invokeMessageAction } from "@in/server/functions/messages.invokeMessageAction"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"

const rejects = async (promise: Promise<unknown>, code: RpcError_Code) => {
  const error = await promise.then(() => undefined, (caught: unknown) => caught)
  expect(RealtimeRpcError.is(error, code)).toBe(true)
}

const widgetMarkdown = [
  "Revenue grew 18% this quarter.",
  "",
  "<iframe title=\"Q3 revenue\" id=\"revenue\" height=\"420\">",
  "<div class=\"card\">",
  "",
  "<button onclick=\"inline.action('pick', {month: 8})\">August</button>",
  "</div>",
  "</iframe>",
  "",
  "The dip in August was the pricing change.",
].join("\n")

describe("message widgets", () => {
  setupTestLifecycle()

  let botId = 0
  let viewerId = 0
  let chatId = 0
  let peer: InputPeer

  beforeEach(async () => {
    const [owner, bot, viewer] = await Promise.all(["owner", "bot", "viewer"].map((name) =>
      testUtils.createUser(`widget-${name}-${crypto.randomUUID()}@example.com`)))
    botId = bot!.id
    viewerId = viewer!.id
    await db.update(users).set({ bot: true, botCreatorId: owner!.id }).where(eq(users.id, botId))
    const chat = await testUtils.createChat(null, "Widgets", "thread", false, owner!.id)
    if (!chat) throw new Error("chat not created")
    chatId = chat.id
    peer = { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } }
    await Promise.all([owner!.id, botId, viewerId].map((id) => testUtils.addParticipant(chatId, id)))
  })

  const send = (userId: number, message: string, isBot: boolean) => sendMessage(
    { peerId: peer, message, parseMarkdown: true },
    { ...testUtils.functionContext({ userId }), isBot },
  )

  const sentMessageId = (result: Awaited<ReturnType<typeof sendMessage>>): bigint => {
    const update = result.updates.find((candidate) => candidate.update.oneofKind === "newMessage")
    return update?.update.oneofKind === "newMessage" ? update.update.newMessage.message!.id : 0n
  }

  test("a bot's AFM preview becomes a widget block whose HTML stays out of the text", async () => {
    const messageId = sentMessageId(await send(botId, widgetMarkdown, true))
    const message = await MessageModel.getMessage(Number(messageId), chatId)

    expect(message.text).toBe("Revenue grew 18% this quarter.\n\nQ3 revenue\n\nThe dip in August was the pricing change.")
    const kinds = message.blockContent?.blocks.map((block) => block.kind.oneofKind)
    expect(kinds).toEqual(["paragraph", "widget", "paragraph"])
    const widget = message.blockContent?.blocks[1]?.kind
    if (widget?.oneofKind !== "widget") throw new Error("expected a widget")
    expect(widget.widget.widgetId).toBe("revenue")
    expect(widget.widget.height).toBe(420)
    expect(widget.widget.html).toContain("inline.action('pick'")
    const title = widget.widget.title!
    expect(message.text!.slice(Number(title.offset), Number(title.offset + title.length))).toBe("Q3 revenue")
  })

  test("people can't send widgets, and a malformed bot widget is rejected", async () => {
    const messageId = sentMessageId(await send(viewerId, widgetMarkdown, false))
    const message = await MessageModel.getMessage(Number(messageId), chatId)
    expect(message.blockContent?.blocks.some((block) => block.kind.oneofKind === "widget") ?? false).toBe(false)

    await rejects(send(botId, "<iframe title=\"Tall\">\n<div style=\"height:100vh\"></div>\n</iframe>", true), RpcError_Code.BAD_REQUEST)
    await rejects(send(botId, "<iframe title=\"Open\">\n<b>never closed</b>", true), RpcError_Code.BAD_REQUEST)
    await rejects(send(botId, "<iframe>a</iframe>\n\n<iframe>b</iframe>", true), RpcError_Code.BAD_REQUEST)
  })

  test("widget calls reach the bot as validated, typed calls", async () => {
    const messageId = sentMessageId(await send(botId, widgetMarkdown, true))
    const call = (actionId: string, name: string, payload: string) => invokeMessageAction({
      peerId: peer,
      messageId,
      actionId,
      widgetCall: { name, payload: new TextEncoder().encode(payload) },
    }, testUtils.functionContext({ userId: viewerId }))

    await rejects(call("missing", "pick", "{}"), RpcError_Code.BAD_REQUEST)
    await rejects(call("revenue", "pick", "{not json"), RpcError_Code.BAD_REQUEST)
    await rejects(call("revenue", "has spaces", "{}"), RpcError_Code.BAD_REQUEST)
    // A widget ID is never treated as a callback button.
    await rejects(invokeMessageAction({ peerId: peer, messageId, actionId: "revenue" }, testUtils.functionContext({ userId: viewerId })), RpcError_Code.BAD_REQUEST)

    const invoked = await call("revenue", "pick", "{\"month\":8}")
    const [stored] = await db.select().from(updates).where(and(
      eq(updates.bucket, UpdateBucket.User),
      eq(updates.entityId, botId),
      eq(updates.seq, Number(invoked.interactionId)),
    ))
    const payload = UpdatesModel.decrypt(stored!).payload.update
    if (payload.oneofKind !== "userMessageActionInvoked") throw new Error("expected an action update")
    expect(payload.userMessageActionInvoked.actionId).toBe("revenue")
    expect(payload.userMessageActionInvoked.data).toHaveLength(0)
    expect(payload.userMessageActionInvoked.widgetCall?.name).toBe("pick")
    expect(new TextDecoder().decode(payload.userMessageActionInvoked.widgetCall?.payload)).toBe("{\"month\":8}")
  })
})
