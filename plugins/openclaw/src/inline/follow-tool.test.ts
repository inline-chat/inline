import { describe, expect, it, vi } from "vitest"

const UPDATE_DIALOG_FOLLOW_MODE = 999

async function loadFollowTool(params: {
  updateError?: Error
  followModes: Array<number | undefined | Error>
}) {
  vi.resetModules()
  const invokeUncheckedRaw = vi.fn(async () => {
    if (params.updateError) throw params.updateError
    return {}
  })
  const getChat = vi.fn(async ({ chatId }: { chatId: bigint }) => {
    const next = params.followModes.shift()
    if (next instanceof Error) throw next
    return { chatId, title: "Room", ...(next != null ? { dialogFollowMode: next } : {}) }
  })
  vi.doMock("@inline-chat/realtime-sdk", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
    return {
      ...actual,
      Method: { ...(actual.Method as object), UPDATE_DIALOG_FOLLOW_MODE },
      InlineSdkClient: class {
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        invokeUncheckedRaw = invokeUncheckedRaw
        getChat = getChat
      },
    }
  })
  const { createInlineFollowTool } = await import("./follow-tool")
  const followCommand = await import("./follow-command")
  const tool = createInlineFollowTool({
    config: { channels: { inline: { token: "token", baseUrl: "https://api.inline.chat" } } } as any,
    messageChannel: "inline",
    sessionKey: "agent:main:inline:group:88:thread:91",
  })
  return { tool, invokeUncheckedRaw, getChat, followCommand }
}

describe("inline/follow-tool", () => {
  it("unfollows the current thread, reads back the state, and marks it for the monitor", async () => {
    const { tool, invokeUncheckedRaw, followCommand } = await loadFollowTool({ followModes: [2] })
    const result = await tool.execute("call", { action: "unfollow" })
    expect(invokeUncheckedRaw).toHaveBeenCalledWith(UPDATE_DIALOG_FOLLOW_MODE, {
      oneofKind: "updateDialogFollowMode",
      updateDialogFollowMode: {
        peerId: { type: { oneofKind: "chat", chat: { chatId: 91n } } },
        followMode: 2,
      },
    })
    expect(result.details).toEqual({ ok: true, accountId: "default", chatId: "91", followMode: "unfollowed" })
    expect(followCommand.takeInlineFollowModeChanged({ accountId: "default", chatId: 91n })).toBe(true)
  })

  it("reads status without writing", async () => {
    const { tool, invokeUncheckedRaw } = await loadFollowTool({ followModes: [undefined] })
    const result = await tool.execute("call", { action: "status", to: "chat:55" })
    expect(invokeUncheckedRaw).not.toHaveBeenCalled()
    expect(result.details).toMatchObject({ chatId: "55", followMode: "default" })
  })

  it("trusts the readback when the write response was lost", async () => {
    const { tool } = await loadFollowTool({ updateError: new Error("socket closed"), followModes: [1] })
    const result = await tool.execute("call", { action: "follow" })
    expect(result.details).toMatchObject({ followMode: "following" })
  })

  it("fails when the readback does not match", async () => {
    const { tool } = await loadFollowTool({ followModes: [0] })
    await expect(tool.execute("call", { action: "follow" })).rejects.toThrow(
      "inline_follow: follow state is default after follow",
    )
  })

  it("reports the write error when the readback also fails", async () => {
    const { tool } = await loadFollowTool({
      updateError: new Error("forbidden"),
      followModes: [new Error("timeout")],
    })
    await expect(tool.execute("call", { action: "unfollow" })).rejects.toThrow("forbidden")
  })

  it("rejects direct-message targets", async () => {
    const { tool } = await loadFollowTool({ followModes: [] })
    await expect(tool.execute("call", { action: "follow", to: "user:42" })).rejects.toThrow(
      "not direct messages",
    )
  })
})
