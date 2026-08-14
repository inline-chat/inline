import { describe, expect, it, vi } from "vitest"
import { BotChatSettingsProblem_Code } from "@inline-chat/realtime-sdk"
import {
  buildOpenClawBotChatSettingsDocument,
  invokeOpenClawBotChatSetting,
  type OpenClawBotChatSettingsContext,
} from "./bot-chat-settings.js"

const context: OpenClawBotChatSettingsContext = {
  scopeId: "chat:42",
  access: "full",
  currentModel: "anthropic/claude-sonnet",
  defaultModel: "openai/gpt-5",
  modelOptions: [
    { value: "anthropic/claude-sonnet", label: "anthropic/claude-sonnet" },
    { value: "openai/gpt-5", label: "openai/gpt-5" },
  ],
  reasoningLevel: "medium",
  reasoningOptions: [
    { value: "medium", label: "Medium" },
    { value: "high", label: "High" },
  ],
  following: true,
  replyThreads: "auto",
  canSetDefaultModel: true,
}

describe("OpenClaw Bot Chat Settings", () => {
  it("keeps the initial panel compact and ordered", () => {
    const document = buildOpenClawBotChatSettingsDocument(context)

    expect(document.version).toBe(1)
    expect(document.revision).toMatch(/^openclaw-v1-/)
    expect(document.sections.map((section) => section.id)).toEqual([
      "runtime",
      "attention",
      "replies",
    ])
    expect(document.sections[0]?.items.map((item) => item.id)).toEqual([
      "model",
      "model-default",
      "reasoning",
    ])
    expect(document.sections[2]?.items[0]?.control).toMatchObject({
      oneofKind: "select",
      select: {
        value: "auto",
        options: [
          { value: "auto", label: "Auto" },
          { value: "on", label: "On" },
          { value: "off", label: "Off" },
        ],
      },
    })
  })

  it("shows reply-thread controls in DMs", () => {
    const document = buildOpenClawBotChatSettingsDocument({
      ...context,
      scopeId: "dm:9",
      following: false,
    })

    expect(document.sections.flatMap((section) => section.items).map((item) => item.id))
      .toContain("reply-threads")
  })

  it("keeps the selected primary in the picker while describing an active backup", () => {
    const document = buildOpenClawBotChatSettingsDocument({
      ...context,
      currentModel: "openai/gpt-5.5",
      activeModel: "minimax/MiniMax-M2.7",
      modelOptions: [
        { value: "openai/gpt-5.5", label: "openai/gpt-5.5" },
        { value: "minimax/MiniMax-M2.7", label: "minimax/MiniMax-M2.7" },
      ],
    })
    const modelItem = document.sections[0]?.items[0]

    expect(modelItem).toMatchObject({
      id: "model",
      description:
        "This session. Using backup minimax/MiniMax-M2.7 after openai/gpt-5.5 failed.",
      control: {
        oneofKind: "select",
        select: { value: "openai/gpt-5.5" },
      },
    })
  })

  it("keeps an unavailable current model visible but prevents selecting it", async () => {
    const unavailableContext: OpenClawBotChatSettingsContext = {
      ...context,
      currentModel: "openai-codex/gpt-5.5",
      modelOptions: [
        {
          value: "openai-codex/gpt-5.5",
          label: "openai-codex/gpt-5.5",
          disabled: true,
        },
        { value: "openai/gpt-5.5", label: "openai/gpt-5.5" },
      ],
    }
    const document = buildOpenClawBotChatSettingsDocument(unavailableContext)
    const setModel = vi.fn(async () => {})

    expect(document.sections[0]?.items[0]).toMatchObject({
      description: "This session. The selected model is unavailable in OpenClaw.",
      control: {
        oneofKind: "select",
        select: {
          value: "openai-codex/gpt-5.5",
          options: [
            { value: "openai-codex/gpt-5.5", disabled: true },
            { value: "openai/gpt-5.5", disabled: false },
          ],
        },
      },
    })

    const response = await invokeOpenClawBotChatSetting({
      context: unavailableContext,
      mutators: { setModel, resolveContext: async () => unavailableContext },
      itemId: "model",
      value: {
        value: { oneofKind: "stringValue", stringValue: "openai-codex/gpt-5.5" },
      },
      documentRevision: document.revision,
    })

    expect(setModel).not.toHaveBeenCalled()
    expect(response.result).toMatchObject({
      oneofKind: "problem",
      problem: { code: BotChatSettingsProblem_Code.INVALID_VALUE, message: "Model unavailable." },
    })
  })

  it("keeps chat controls writable while hiding an unauthorized global action", () => {
    const document = buildOpenClawBotChatSettingsDocument({
      ...context,
      canSetDefaultModel: false,
    })
    const items = document.sections.flatMap((section) => section.items)

    expect(items.map((item) => item.id)).not.toContain("model-default")
    expect(items.filter((item) => item.id !== "runtime-unavailable").every((item) => !item.disabled))
      .toBe(true)
  })

  it("returns a full replacement after a live mutation", async () => {
    let current = context
    const setReplyThreads = vi.fn(async (value: "auto" | "on" | "off") => {
      current = { ...current, replyThreads: value }
    })
    const original = buildOpenClawBotChatSettingsDocument(current)

    const response = await invokeOpenClawBotChatSetting({
      context: current,
      mutators: {
        setReplyThreads,
        resolveContext: async () => current,
      },
      itemId: "reply-threads",
      value: { value: { oneofKind: "stringValue", stringValue: "on" } },
      documentRevision: original.revision,
    })

    expect(setReplyThreads).toHaveBeenCalledWith("on")
    expect(response.result.oneofKind).toBe("document")
    if (response.result.oneofKind !== "document") throw new Error("missing document")
    expect(response.result.document.sections[2]?.items[0]?.control).toMatchObject({
      oneofKind: "select",
      select: { value: "on" },
    })
  })

  it("returns the current document with stale and access problems", async () => {
    const mutators = { resolveContext: async () => context }
    const stale = await invokeOpenClawBotChatSetting({
      context,
      mutators,
      itemId: "reply-threads",
      value: { value: { oneofKind: "stringValue", stringValue: "on" } },
      documentRevision: "stale",
    })
    expect(stale.result).toMatchObject({
      oneofKind: "problem",
      problem: {
        code: BotChatSettingsProblem_Code.STALE,
        currentDocument: { version: 1 },
      },
    })

    const readOnly = { ...context, access: "readOnly" as const }
    const denied = await invokeOpenClawBotChatSetting({
      context: readOnly,
      mutators: { resolveContext: async () => readOnly },
      itemId: "following",
      value: { value: { oneofKind: "boolValue", boolValue: false } },
      documentRevision: buildOpenClawBotChatSettingsDocument(readOnly).revision,
    })
    expect(denied.result).toMatchObject({
      oneofKind: "problem",
      problem: { code: BotChatSettingsProblem_Code.FAILED },
    })
  })

  it("does not expose runtime state when inspection is disallowed", () => {
    const document = buildOpenClawBotChatSettingsDocument({
      scopeId: "chat:42",
      access: "guideOnly",
      replyThreads: "auto",
    })

    expect(document.sections.map((section) => section.id)).toEqual(["access"])
    expect(JSON.stringify(document)).not.toContain("claude-sonnet")
  })

})
