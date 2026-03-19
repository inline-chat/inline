import { beforeEach, describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

const connect = vi.fn(async () => {})
const close = vi.fn(async () => {})
const getMe = vi.fn(async () => ({ userId: 42n }))
const uploadFile = vi.fn(async () => ({
  fileUniqueId: "uploaded-photo-1",
  photoId: 77n,
}))
const invokeRaw = vi.fn(async (_method: number, _input: unknown) => ({
  oneofKind: "updateBotProfile",
  updateBotProfile: {
    bot: {
      id: 42n,
      firstName: "Updated Bot",
    },
  },
}))
const loadWebMedia = vi.fn(async () => ({
  kind: "image" as const,
  buffer: new Uint8Array([1, 2, 3]),
  fileName: "photo.png",
  contentType: "image/png",
}))
const detectMime = vi.fn(async () => "image/png")

vi.mock("@inline-chat/realtime-sdk", () => ({
  Method: {
    UPDATE_BOT_PROFILE: 37,
  },
  InlineSdkClient: class {
    constructor(_opts: unknown) {}
    connect = connect
    close = close
    getMe = getMe
    uploadFile = uploadFile
    invokeRaw = invokeRaw
  },
}))

vi.mock("openclaw/plugin-sdk", async () => {
  const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
  return {
    ...actual,
    loadWebMedia,
    detectMime,
  }
})

describe("inline/profile-tool", () => {
  beforeEach(() => {
    connect.mockClear()
    close.mockClear()
    getMe.mockClear()
    uploadFile.mockClear()
    invokeRaw.mockClear()
    loadWebMedia.mockClear()
    detectMime.mockClear()
  })

  it("updates bot profile name and photo", async () => {
    const { createInlineProfileTool } = await import("./profile-tool")

    const tool = createInlineProfileTool({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
    })

    const result = await tool?.execute("tool-1", {
      name: "Updated Bot",
      photoPath: "/tmp/photo.png",
    })

    expect(uploadFile).toHaveBeenCalledWith({
      type: "photo",
      file: expect.any(Uint8Array),
      fileName: "photo.png",
      contentType: "image/png",
    })
    expect(invokeRaw).toHaveBeenCalledWith(37, {
      oneofKind: "updateBotProfile",
      updateBotProfile: {
        botUserId: 42n,
        name: "Updated Bot",
        photoFileUniqueId: "uploaded-photo-1",
      },
    })
    expect(result).toMatchObject({
      details: {
        ok: true,
        accountId: "default",
        botUserId: "42",
        updated: {
          name: "Updated Bot",
          photo: true,
        },
      },
    })
  })

  it("rejects when neither name nor photo is provided", async () => {
    const { createInlineProfileTool } = await import("./profile-tool")

    const tool = createInlineProfileTool({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
    })

    await expect(tool?.execute("tool-2", {})).rejects.toThrow(/provide `name` and\/or `photo`/)
  })
})
