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
