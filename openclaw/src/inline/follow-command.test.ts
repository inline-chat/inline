import { describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginCommandContext } from "openclaw/plugin-sdk"
import { DialogFollowMode, Method } from "@inline-chat/realtime-sdk"
import {
  createInlineFollowCommands,
  handleInlineFollowCommand,
  inlineFollowCommandFailureText,
  inlineFollowCommandSuccessText,
  listInlineFollowCommandSpecs,
  parseInlineFollowCommandBody,
  resolveInlineFollowCommandTarget,
  summarizeInlineFollowCommandError,
  updateInlineFollowMode,
} from "./follow-command"

function commandCtx(overrides: Partial<PluginCommandContext> = {}): PluginCommandContext {
  return {
    channel: "inline",
    channelId: "inline",
    isAuthorizedSender: true,
    commandBody: "/follow",
    args: "",
    senderId: "42",
    from: "inline:chat:123",
    to: "inline:123",
    accountId: "default",
    requestConversationBinding: async () => ({ status: "error", message: "unused" }),
    detachConversationBinding: async () => ({ removed: false }),
    getCurrentConversationBinding: async () => null,
    ...overrides,
  }
}

function api(): OpenClawPluginApi {
  return {
    logger: {
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    },
  } as unknown as OpenClawPluginApi
}

describe("inline/follow-command", () => {
  it("publishes follow and unfollow as no-argument Inline commands", () => {
    expect(listInlineFollowCommandSpecs()).toEqual([
      {
        name: "follow",
        description: "Explicitly follow this Inline chat or thread",
        acceptsArgs: false,
      },
      {
        name: "unfollow",
        description: "Explicitly unfollow this Inline chat or thread",
        acceptsArgs: false,
      },
    ])

    const commands = createInlineFollowCommands(api())
    expect(commands.map((command) => command.name)).toEqual(["follow", "unfollow"])
    expect(commands.every((command) => command.channels?.includes("inline"))).toBe(true)
  })

  it("parses case-insensitive commands and preserves unexpected arguments", () => {
    expect(parseInlineFollowCommandBody(" /FOLLOW ")).toEqual({ command: "follow", args: "" })
    expect(parseInlineFollowCommandBody("/unfollow now please")).toEqual({
      command: "unfollow",
      args: "now please",
    })
    expect(parseInlineFollowCommandBody("/following")).toBeNull()
  })

  it("targets the current reply thread before the parent group", () => {
    expect(resolveInlineFollowCommandTarget(commandCtx({ messageThreadId: "456" }))).toEqual({
      chatId: 456n,
    })
    expect(resolveInlineFollowCommandTarget(commandCtx())).toEqual({ chatId: 123n })
    expect(
      resolveInlineFollowCommandTarget(commandCtx({ from: "inline:42", senderId: "42" })),
    ).toEqual({ userId: 42n })
  })

  it("sends FOLLOWING for a chat and explicit UNFOLLOWED for a user", async () => {
    const invokeUncheckedRaw = vi.fn(async () => ({ oneofKind: "updateDialogFollowMode" }))
    const client = { invokeUncheckedRaw }

    await expect(
      updateInlineFollowMode({ client, target: { chatId: 123n }, command: "follow" }),
    ).resolves.toBe("following")
    await expect(
      updateInlineFollowMode({ client, target: { userId: 42n }, command: "unfollow" }),
    ).resolves.toBe("unfollowed")

    expect(invokeUncheckedRaw).toHaveBeenNthCalledWith(1, Method.UPDATE_DIALOG_FOLLOW_MODE, {
      oneofKind: "updateDialogFollowMode",
      updateDialogFollowMode: {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 123n },
          },
        },
        followMode: DialogFollowMode.FOLLOWING,
      },
    })
    expect(invokeUncheckedRaw).toHaveBeenNthCalledWith(2, Method.UPDATE_DIALOG_FOLLOW_MODE, {
      oneofKind: "updateDialogFollowMode",
      updateDialogFollowMode: {
        peerId: {
          type: {
            oneofKind: "user",
            user: { userId: 42n },
          },
        },
        followMode: 2,
      },
    })
  })

  it("rejects unauthorized commands and unexpected arguments before connecting", async () => {
    const pluginApi = api()
    await expect(
      handleInlineFollowCommand(pluginApi, "follow", commandCtx({ isAuthorizedSender: false })),
    ).resolves.toEqual({ text: "This command requires authorization." })
    await expect(
      handleInlineFollowCommand(pluginApi, "unfollow", commandCtx({ args: "later" })),
    ).resolves.toEqual({ text: "Usage: /unfollow" })
  })

  it("uses distinct success and retryable failure copy", () => {
    expect(inlineFollowCommandSuccessText("follow")).toContain("wake OpenClaw without an @mention")
    expect(inlineFollowCommandSuccessText("unfollow")).toContain("Automatic follow and reply wakes are disabled")
    expect(inlineFollowCommandFailureText("follow")).toBe(
      "Could not update Inline follow mode. Try /follow again.",
    )
  })

  it("bounds and redacts errors before logging", () => {
    expect(
      summarizeInlineFollowCommandError(
        new Error("connect https://user:secret@api.inline.chat/realtime?token=secret Bearer token-value"),
      ),
    ).toBe("Error: connect https://api.inline.chat Bearer <redacted>")
    expect(summarizeInlineFollowCommandError("x".repeat(700))).toHaveLength(500)
  })
})
