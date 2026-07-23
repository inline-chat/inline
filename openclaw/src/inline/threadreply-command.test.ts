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
    commandBody: "/threadreply",
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

    expect(command.name).toBe("threadreply")
    expect(command.channels).toEqual(["inline"])
    expect(command.acceptsArgs).toBe(true)
  })

  it("renders mode buttons when no argument is supplied", async () => {
    const { api } = createApi({
      channels: {
        inline: {
          groups: {
            "123": { replyThreadMode: "main" },
          },
        },
      },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(api, commandCtx())

    expect(result.text).toContain("Thread reply mode for chat 123: main.")
    expect(result.channelData).toEqual({
      inline: {
        buttons: [
          [
            { text: "Thread", callback_data: "/threadreply thread" },
            { text: "Main", callback_data: "/threadreply main" },
            { text: "Auto", callback_data: "/threadreply auto" },
          ],
          [{ text: "Inherit Mode", callback_data: "/threadreply inherit" }],
        ],
      },
    })
  })

  it("explains that legacy auto-create minimums are ignored", async () => {
    const { api, mutateConfigFile } = createApi({})

    const result = await handleInlineThreadReplyCommand(api, commandCtx({ args: "min 50" }))

    expect(result.text).toContain("message IDs are not chat message counts")
    expect(mutateConfigFile).not.toHaveBeenCalled()
  })

  it("sets the current top-level Inline group mode", async () => {
    const { api, current, mutateConfigFile } = createApi({
      channels: {
        inline: {
          groups: {
            "123": {
              requireMention: true,
            },
          },
        },
      },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(api, commandCtx({ args: "thread" }))

    expect(mutateConfigFile).toHaveBeenCalledTimes(1)
    expect(result.text).toContain("Thread reply mode for chat 123: thread.")
    expect(inlineConfig(current()).groups?.["123"]).toEqual({
      requireMention: true,
      replyThreadMode: "thread",
    })
  })

  it("sets named account group mode without touching top-level groups", async () => {
    const { api, current } = createApi({
      channels: {
        inline: {
          groups: {
            "123": { replyThreadMode: "main" },
          },
          accounts: {
            work: {
              groups: {
                "123": { requireMention: true },
              },
            },
          },
        },
      },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(
      api,
      commandCtx({ accountId: "work", args: "auto" }),
    )
    const inline = inlineConfig(current())

    expect(result.text).toContain("Thread reply mode for chat 123: auto.")
    expect(inline.groups?.["123"]?.replyThreadMode).toBe("main")
    expect(inline.accounts?.work?.groups?.["123"]).toEqual({
      requireMention: true,
      replyThreadMode: "auto",
    })
  })

  it("removes the chat override with inherit", async () => {
    const { api, current } = createApi({
      channels: {
        inline: {
          replyThreadMode: "thread",
          groups: {
            "123": {
              requireMention: true,
              replyThreadMode: "main",
            },
          },
        },
      },
    } as OpenClawConfig)

    const result = await handleInlineThreadReplyCommand(api, commandCtx({ args: "inherit" }))

    expect(result.text).toContain("Thread reply mode for chat 123: thread.")
    expect(inlineConfig(current()).groups?.["123"]).toEqual({
      requireMention: true,
    })
  })

  it("rejects direct-message contexts", async () => {
    const { api, mutateConfigFile } = createApi({})

    const result = await handleInlineThreadReplyCommand(
      api,
      commandCtx({ from: "inline:51", to: "inline:7000", args: "thread" }),
    )

    expect(result.text).toBe("/threadreply is only available in Inline group chats.")
    expect(mutateConfigFile).not.toHaveBeenCalled()
  })

  it("rejects unauthorized contexts", async () => {
    const { api, mutateConfigFile } = createApi({})

    const result = await handleInlineThreadReplyCommand(
      api,
      commandCtx({ isAuthorizedSender: false, args: "thread" }),
    )

    expect(result.text).toBe("This command requires authorization.")
    expect(mutateConfigFile).not.toHaveBeenCalled()
  })
})
