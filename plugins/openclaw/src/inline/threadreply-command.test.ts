import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig, OpenClawPluginApi, PluginCommandContext } from "openclaw/plugin-sdk"
import {
  createInlineThreadReplyCommand,
  handleInlineThreadReplyCommand,
} from "./threadreply-command"

type InlineTestConfig = {
  groups?: Record<string, Record<string, unknown> | undefined> | undefined
  accounts?:
    | Record<string, { groups?: Record<string, Record<string, unknown> | undefined> | undefined }>
    | undefined
}

function cloneConfig(cfg: OpenClawConfig): OpenClawConfig {
  return structuredClone(cfg) as OpenClawConfig
}

function inlineConfig(cfg: OpenClawConfig): InlineTestConfig {
  const inline = cfg.channels?.inline
  expect(inline).toBeDefined()
  return inline as InlineTestConfig
}

function createApi(initialConfig: OpenClawConfig): {
  api: OpenClawPluginApi
  current: () => OpenClawConfig
  mutateConfigFile: ReturnType<typeof vi.fn>
} {
  let current = cloneConfig(initialConfig)
  const mutateConfigFile = vi.fn(async ({ mutate }: { mutate: (draft: OpenClawConfig) => void }) => {
    const draft = cloneConfig(current)
    mutate(draft)
    current = draft
    return {
      previousHash: "before",
      persistedHash: "after",
      nextConfig: current,
      result: undefined,
    }
  })
  const api = {
    runtime: {
      config: {
        current: () => current,
        mutateConfigFile,
      },
    },
  } as unknown as OpenClawPluginApi

  return {
    api,
    current: () => current,
    mutateConfigFile,
  }
}

function commandCtx(overrides: Partial<PluginCommandContext> = {}): PluginCommandContext {
  return {
    channel: "inline",
    channelId: "inline",
    isAuthorizedSender: true,
    commandBody: "/threads",
    args: "",
    from: "inline:chat:123",
    to: "inline:123",
    accountId: "default",
    requestConversationBinding: async () => ({ status: "error", message: "unused" }),
    detachConversationBinding: async () => ({ removed: false }),
    getCurrentConversationBinding: async () => null,
    ...overrides,
  }
}

describe("inline/threadreply-command", () => {
  it("registers an Inline-scoped plugin command", () => {
    const { api } = createApi({})
    const command = createInlineThreadReplyCommand(api)

    expect(command.name).toBe("threads")
    expect(command.channels).toEqual(["inline"])
    expect(command.acceptsArgs).toBe(true)
  })

  it("renders Auto and On buttons when no argument is supplied", async () => {
    const { api } = createApi({})

    const result = await handleInlineThreadReplyCommand(api, commandCtx())

    expect(result.text).toContain("Reply threads in this chat: Auto.")
    expect(result.channelData).toEqual({
      inline: {
        buttons: [[
          { text: "Auto", callback_data: "/threads auto" },
          { text: "On", callback_data: "/threads on" },
        ]],
      },
    })
  })

  it("reads the old names on a chat: thread is On, main is Auto", async () => {
    const { api } = createApi({
      channels: { inline: { groups: { "123": { replyThreadMode: "thread" }, "124": { replyThreadMode: "main" } } } },
    } as OpenClawConfig)

    const on = await handleInlineThreadReplyCommand(api, commandCtx({ args: "status" }))
    const auto = await handleInlineThreadReplyCommand(api, commandCtx({ args: "status", to: "inline:124" }))

    expect(on.text).toContain("On.")
    expect(auto.text).toContain("Auto.")
  })

  it("sets the current chat's mode and keeps its other settings", async () => {
    const { api, current, mutateConfigFile } = createApi({
      channels: { inline: { groups: { "123": { requireMention: true } } } },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(api, commandCtx({ args: "on" }))

    expect(mutateConfigFile).toHaveBeenCalledWith(expect.objectContaining({
      afterWrite: {
        mode: "none",
        reason: "Inline reads the refreshed runtime config in-process.",
      },
    }))
    expect(result.text).toContain("Reply threads in this chat: On.")
    expect(inlineConfig(current()).groups?.["123"]).toEqual({
      requireMention: true,
      replyThreadMode: "on",
    })
  })

  it("works in a DM, keyed by its chat", async () => {
    const { api, current } = createApi({})

    const result = await handleInlineThreadReplyCommand(
      api,
      commandCtx({ args: "on", from: "inline:42", to: "inline:900" }),
    )

    expect(result.text).toContain("Reply threads in this chat: On.")
    expect(inlineConfig(current()).groups?.["900"]?.replyThreadMode).toBe("on")
  })

  it("sets a named account's chat without touching top-level groups", async () => {
    const { api, current } = createApi({
      channels: {
        inline: {
          groups: { "123": { replyThreadMode: "on" } },
          accounts: { work: { groups: { "123": { requireMention: true } } } },
        },
      },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(
      api,
      commandCtx({ accountId: "work", args: "auto" }),
    )
    const inline = inlineConfig(current())

    expect(result.text).toContain("Reply threads in this chat: Auto.")
    expect(inline.groups?.["123"]?.replyThreadMode).toBe("on")
    expect(inline.accounts?.work?.groups?.["123"]).toEqual({
      requireMention: true,
      replyThreadMode: "auto",
    })
  })

  it("reset removes the chat's setting, back to Auto", async () => {
    const { api, current } = createApi({
      channels: {
        inline: {
          replyThreadMode: "thread",
          groups: { "123": { requireMention: true, replyThreadMode: "on" } },
        },
      },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(api, commandCtx({ args: "reset" }))

    expect(result.text).toContain("Reply threads in this chat: Auto.")
    expect(inlineConfig(current()).groups?.["123"]).toEqual({ requireMention: true })
  })

  it("rejects unauthorized senders and unknown modes", async () => {
    const { api, mutateConfigFile } = createApi({})

    const denied = await handleInlineThreadReplyCommand(api, commandCtx({ isAuthorizedSender: false, args: "on" }))
    const unknown = await handleInlineThreadReplyCommand(api, commandCtx({ args: "sideways" }))

    expect(denied.text).toBe("This command requires authorization.")
    expect(unknown.text).toContain("Usage: /threads")
    expect(mutateConfigFile).not.toHaveBeenCalled()
  })
})
