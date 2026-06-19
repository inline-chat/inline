import { beforeEach, describe, expect, it, vi } from "vitest"
import { deflateRawSync } from "node:zlib"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

const connect = vi.fn(async () => {})
const close = vi.fn(async () => {})
const getMe = vi.fn(async () => ({ userId: 42n }))
const uploadFile = vi.fn(async () => ({
  fileUniqueId: "uploaded-avatar-1",
  photoId: 77n,
}))
const invokeRaw = vi.fn(async (method: number, _input: unknown) => {
  if (method === 57) {
    return {
      oneofKind: "clearBotAvatar",
      clearBotAvatar: {
        bot: {
          id: 42n,
          firstName: "OpenClaw",
        },
      },
    }
  }
  return {
    oneofKind: "setBotAvatar",
    setBotAvatar: {
      bot: {
        id: 42n,
        firstName: "OpenClaw",
      },
    },
  }
})
let zipBuffer = createAvatarZip()
const loadWebMedia = vi.fn(async () => ({
  kind: "document" as const,
  buffer: zipBuffer,
  fileName: "zhu-bajie.zip",
  contentType: "application/zip",
}))
const detectMime = vi.fn(async () => "application/zip")

vi.mock("@inline-chat/realtime-sdk", () => ({
  BotAvatar_Kind: {
    CODEX_ATLAS: 1,
  },
  Method: {
    SET_BOT_AVATAR: 56,
    CLEAR_BOT_AVATAR: 57,
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

function uint16(value: number): Buffer {
  const buffer = Buffer.alloc(2)
  buffer.writeUInt16LE(value)
  return buffer
}

function uint32(value: number): Buffer {
  const buffer = Buffer.alloc(4)
  buffer.writeUInt32LE(value)
  return buffer
}

function createAvatarZip(options?: { method?: "store" | "deflate" }): Buffer {
  return createZip(
    [
      {
        name: "zhu/pet.json",
        data: Buffer.from(
          JSON.stringify({
            id: "zhu-bajie",
            displayName: "Zhu Bajie",
            description: "A lively avatar.",
            spritesheetPath: "spritesheet.webp",
          }),
        ),
      },
      {
        name: "zhu/spritesheet.webp",
        data: Buffer.from([1, 2, 3, 4]),
      },
    ],
    options,
  )
}

function createZip(
  entries: Array<{ name: string; data: Buffer; uncompressedSize?: number }>,
  options?: { method?: "store" | "deflate" },
): Buffer {
  const locals: Buffer[] = []
  const centrals: Buffer[] = []
  let offset = 0
  const method = options?.method === "deflate" ? 8 : 0

  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8")
    const compressed = method === 8 ? deflateRawSync(entry.data) : entry.data
    const uncompressedSize = entry.uncompressedSize ?? entry.data.length
    const local = Buffer.concat([
      uint32(0x04034b50),
      uint16(20),
      uint16(0),
      uint16(method),
      uint16(0),
      uint16(0),
      uint32(0),
      uint32(compressed.length),
      uint32(uncompressedSize),
      uint16(name.length),
      uint16(0),
      name,
      compressed,
    ])
    const central = Buffer.concat([
      uint32(0x02014b50),
      uint16(20),
      uint16(20),
      uint16(0),
      uint16(method),
      uint16(0),
      uint16(0),
      uint32(0),
      uint32(compressed.length),
      uint32(uncompressedSize),
      uint16(name.length),
      uint16(0),
      uint16(0),
      uint16(0),
      uint16(0),
      uint32(0),
      uint32(offset),
      name,
    ])
    locals.push(local)
    centrals.push(central)
    offset += local.length
  }

  const centralDirectory = Buffer.concat(centrals)
  const eocd = Buffer.concat([
    uint32(0x06054b50),
    uint16(0),
    uint16(0),
    uint16(entries.length),
    uint16(entries.length),
    uint32(centralDirectory.length),
    uint32(offset),
    uint16(0),
  ])

  return Buffer.concat([...locals, centralDirectory, eocd])
}

describe("inline/bot-avatar-tool", () => {
  beforeEach(async () => {
    connect.mockClear()
    close.mockClear()
    getMe.mockClear()
    uploadFile.mockClear()
    invokeRaw.mockClear()
    loadWebMedia.mockClear()
    detectMime.mockClear()
    zipBuffer = createAvatarZip()

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      media: {
        loadWebMedia,
        detectMime,
      },
    } as any)
  })

  it("uploads a zip avatar package for the authenticated bot", async () => {
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
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
      zipPath: "/Users/mo/Downloads/zhu-bajie.zip",
    })

    expect(loadWebMedia).toHaveBeenCalledWith("/Users/mo/Downloads/zhu-bajie.zip", {
      maxBytes: 40_000_000,
      optimizeImages: false,
      localRoots: ["/Users/mo/Downloads"],
    })
    expect(uploadFile).toHaveBeenCalledWith({
      type: "photo",
      file: expect.any(Buffer),
      fileName: "spritesheet.webp",
      contentType: "image/webp",
    })
    expect(invokeRaw).toHaveBeenCalledWith(56, {
      oneofKind: "setBotAvatar",
      setBotAvatar: {
        botUserId: 42n,
        kind: 1,
        displayName: "Zhu Bajie",
        description: "A lively avatar.",
        fileUniqueId: "uploaded-avatar-1",
      },
    })
    expect(result).toMatchObject({
      details: {
        ok: true,
        accountId: "default",
        botUserId: "42",
        avatar: {
          kind: "codex_atlas",
          id: "zhu-bajie",
          displayName: "Zhu Bajie",
          description: "A lively avatar.",
          spritesheetPath: "zhu/spritesheet.webp",
        },
        uploaded: {
          fileUniqueId: "uploaded-avatar-1",
          fileName: "spritesheet.webp",
          contentType: "image/webp",
        },
      },
    })
  })

  it("clears the authenticated bot avatar without loading a package", async () => {
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
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

    const result = await tool?.execute("tool-clear", {
      action: "clear",
    })

    expect(loadWebMedia).not.toHaveBeenCalled()
    expect(uploadFile).not.toHaveBeenCalled()
    expect(invokeRaw).toHaveBeenCalledWith(57, {
      oneofKind: "clearBotAvatar",
      clearBotAvatar: {
        botUserId: 42n,
      },
    })
    expect(result).toMatchObject({
      details: {
        ok: true,
        action: "clear",
        accountId: "default",
        botUserId: "42",
        cleared: true,
        avatar: null,
      },
    })
  })

  it("rejects clear requests that also provide avatar package metadata", async () => {
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
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

    await expect(
      tool?.execute("tool-ambiguous-clear", {
        action: "clear",
        source: "/Users/mo/Downloads/zhu-bajie.zip",
      }),
    ).rejects.toThrow(/clear action must not include avatar package/)
    expect(loadWebMedia).not.toHaveBeenCalled()
    expect(uploadFile).not.toHaveBeenCalled()
    expect(invokeRaw).not.toHaveBeenCalled()
  })

  it("extracts deflated zip packages", async () => {
    zipBuffer = createAvatarZip({ method: "deflate" })
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
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

    await tool?.execute("tool-deflate", {
      zipPath: "/Users/mo/Downloads/zhu-bajie.zip",
    })

    expect(uploadFile).toHaveBeenCalledWith({
      type: "photo",
      file: expect.any(Buffer),
      fileName: "spritesheet.webp",
      contentType: "image/webp",
    })
    expect(invokeRaw).toHaveBeenCalledWith(56, expect.objectContaining({
      oneofKind: "setBotAvatar",
    }))
  })

  it("keeps local archive reads inside the workspace when fs is workspace-only", async () => {
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
      workspaceDir: "/Users/mo/dev/inline-chat/inline",
      fsPolicy: { workspaceOnly: true },
    })

    await tool?.execute("tool-workspace", {
      zipPath: "/Users/mo/Downloads/zhu-bajie.zip",
    })

    expect(loadWebMedia).toHaveBeenCalledWith("/Users/mo/Downloads/zhu-bajie.zip", {
      maxBytes: 40_000_000,
      optimizeImages: false,
      workspaceDir: "/Users/mo/dev/inline-chat/inline",
      localRoots: ["/Users/mo/dev/inline-chat/inline"],
    })
  })

  it("rejects deflated entries that inflate past the declared cap", async () => {
    zipBuffer = createZip(
      [
        {
          name: "pet.json",
          data: Buffer.alloc(70_000, 123),
          uncompressedSize: 10,
        },
      ],
      { method: "deflate" },
    )
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
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

    await expect(
      tool?.execute("tool-oversized", {
        zipPath: "/Users/mo/Downloads/zhu-bajie.zip",
      }),
    ).rejects.toThrow(/invalid or oversized zip entry/)
    expect(uploadFile).not.toHaveBeenCalled()
    expect(invokeRaw).not.toHaveBeenCalled()
  })

  it("requires a zip source", async () => {
    const { createInlineBotAvatarTool } = await import("./bot-avatar-tool")

    const tool = createInlineBotAvatarTool({
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

    await expect(tool?.execute("tool-2", { source: "/tmp/avatar.txt" })).rejects.toThrow(
      /source must be a \.zip package/,
    )
    expect(loadWebMedia).not.toHaveBeenCalled()
  })
})
