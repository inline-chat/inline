import { beforeEach, describe, expect, test, vi } from "vitest"
import type { InputPeer } from "@inline-chat/protocol/core"
import type { ResolveUrlPreviewInput, ResolvedUrlPreview } from "@in/server/modules/urlPreview/processUrlPreview"
import type { HandlerContext } from "@in/server/realtime/types"
import { resolveUrlPreviewHandler } from "./urlPreview.resolve"

const mocks = vi.hoisted(() => ({
  getChat: vi.fn(),
  ensureChatAccess: vi.fn(),
  resolvePreview: vi.fn<(input: ResolveUrlPreviewInput) => Promise<ResolvedUrlPreview | null>>(),
}))

vi.mock("@in/server/db/models/chats", () => ({ ChatModel: { getChatFromInputPeer: mocks.getChat } }))
vi.mock("@in/server/db/models/files", () => ({ FileModel: {} }))
vi.mock("@in/server/modules/authorization/accessGuards", () => ({
  AccessGuards: { ensureChatAccess: mocks.ensureChatAccess },
}))
vi.mock("@in/server/modules/urlPreview/processUrlPreview", () => ({ resolveUrlPreview: mocks.resolvePreview }))
vi.mock("@in/server/realtime/encoders/encodePhoto", () => ({ encodePhoto: vi.fn() }))

const url = "https://app.notion.com/p/example/22222222222242228222222222222222?v=33333333333343338333333333333333"
const peer: InputPeer = { type: { oneofKind: "chat", chat: { chatId: 42n } } }
const context: HandlerContext = {
  userId: 7, sessionId: 1, connectionId: "notion-test", sendRaw() {}, sendRpcReply() {},
}

beforeEach(() => {
  mocks.getChat.mockResolvedValue({ id: 42, spaceId: 10 })
  mocks.ensureChatAccess.mockResolvedValue(undefined)
  mocks.resolvePreview.mockResolvedValue({
    metadata: { url, finalUrl: url, provider: "notion", providerResourceType: "notion.database", title: "Reminders", iconEmoji: "⏰" },
    photoId: null,
    authorPhotoId: null,
  })
})

describe("URL preview lookup authorization", () => {
  test("omitting the peer forwards only the authenticated user to personal lookup", async () => {
    const result = await resolveUrlPreviewHandler({ url }, context)
    expect(mocks.getChat).not.toHaveBeenCalled()
    expect(mocks.ensureChatAccess).not.toHaveBeenCalled()
    expect(mocks.resolvePreview).toHaveBeenCalledWith({ url, currentUserId: 7 })
    expect(result.canSubstitute).toBe(true)
    expect(result.urlPreview).toMatchObject({ url, title: "Reminders", iconEmoji: "⏰" })
  })

  test("a supplied peer still requires chat authorization and retains its space context", async () => {
    await resolveUrlPreviewHandler({ url, peerId: peer }, context)
    expect(mocks.getChat).toHaveBeenCalledWith(peer, { currentUserId: 7 })
    expect(mocks.ensureChatAccess).toHaveBeenCalledWith({ id: 42, spaceId: 10 }, 7)
    expect(mocks.resolvePreview).toHaveBeenCalledWith({ url, currentUserId: 7, chatId: 42, spaceId: 10 })
  })

  test("denied chat access does not fall back to personal lookup", async () => {
    mocks.ensureChatAccess.mockRejectedValueOnce(new Error("Access denied"))
    await expect(resolveUrlPreviewHandler({ url, peerId: peer }, context)).rejects.toThrow("Access denied")
    expect(mocks.resolvePreview).not.toHaveBeenCalled()
  })

  test("bots cannot use the new peerless lookup path", async () => {
    await expect(resolveUrlPreviewHandler({ url }, { ...context, isBot: true })).rejects.toThrow()
    expect(mocks.resolvePreview).not.toHaveBeenCalled()
    expect(mocks.getChat).not.toHaveBeenCalled()
  })
})
