import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { describe, expect, it, vi } from "vitest"
import {
  createInlineWidgetPresenter,
  registerInlineWidgetPresenter,
  resolveInlineWidgetDestination,
} from "./widget-presenter.js"
import { OPENCLAW_WIDGET_COMPAT_PRELUDE } from "./widgets.js"

const cfg = {
  channels: { inline: { enabled: true, token: "test-token", baseUrl: "https://api.inline.test" } },
} as unknown as OpenClawConfig

const inlineContext = {
  messageChannel: "inline",
  accountId: "default",
  deliveryContext: { channel: "inline", to: "inline:42", accountId: "default" },
}

function openClawDocument(code: string): string {
  const bridge = "<script>(()=>{if(!window.parent||window.parent===window)return;})();</script>"
  return `<!doctype html>\n<html><head><title>T</title></head><body>${bridge}${bridge}${code}</body></html>`
}

function setup(sendResult: { messageId?: bigint | null } = { messageId: 901n }) {
  const sendMessage = vi.fn(async (_params: Record<string, unknown>) => sendResult)
  const connect = vi.fn(async () => {})
  const close = vi.fn(async () => {})
  const createClient = vi.fn((_params: { baseUrl: string; token: string }) => ({ connect, close, sendMessage }))
  const presenter = createInlineWidgetPresenter({
    readConfig: () => cfg,
    createClient: createClient as never,
    now: () => 1_700_000_000_000,
  })
  return { presenter, sendMessage, connect, close, createClient }
}

describe("inline widget presenter", () => {
  it("declares a current-channel HTML presenter capped at 256 KiB", () => {
    const { presenter } = setup()
    expect(presenter.target).toBe("current_channel")
    expect(presenter.target === "current_channel" && presenter.capabilities).toEqual({
      sourceKinds: ["html"],
      maxSourceBytes: 256 * 1024,
    })
  })

  it("matches only Inline contexts with a resolvable chat", () => {
    const { presenter } = setup()
    const match = presenter.target === "current_channel" ? presenter.match : () => false
    expect(match(inlineContext)).toBe(true)
    expect(match({ messageChannel: "discord", deliveryContext: { channel: "discord", to: "123" } })).toBe(false)
    expect(match({ messageChannel: "inline", deliveryContext: { channel: "telegram", to: "42" } })).toBe(false)
    expect(match({ messageChannel: "inline" })).toBe(false)
    expect(match({ messageChannel: "inline", sessionKey: "agent:main:inline:chat:42" })).toBe(true)
  })

  it("routes reply threads to the child chat and user targets to the DM", () => {
    expect(resolveInlineWidgetDestination({
      messageChannel: "inline",
      deliveryContext: { channel: "inline", to: "inline:42", threadId: "77" },
    })).toEqual({ accountId: null, send: { chatId: 77n }, threadId: "77" })
    expect(resolveInlineWidgetDestination({
      messageChannel: "inline",
      deliveryContext: { channel: "inline", to: "user:9" },
    })).toEqual({ accountId: null, send: { userId: 9n } })
    expect(resolveInlineWidgetDestination({
      messageChannel: "inline",
      sessionKey: "agent:main:inline:chat:42:thread:77",
    })).toEqual({ accountId: null, send: { chatId: 77n }, threadId: "77" })
  })

  it("sends the widget as one Markdown message to the current chat", async () => {
    const { presenter, sendMessage, connect, close, createClient } = setup()
    const result = await presenter.present({
      document: { kind: "html", html: openClawDocument(`<div class="card">Q3</div>`) },
      title: `Q3 "revenue" <net>`,
      context: inlineContext,
    })

    expect(createClient).toHaveBeenCalledWith({ baseUrl: "https://api.inline.test", token: "test-token" })
    expect(connect).toHaveBeenCalledTimes(1)
    expect(sendMessage).toHaveBeenCalledTimes(1)
    expect(sendMessage).toHaveBeenCalledWith({
      chatId: 42n,
      parseMarkdown: true,
      text:
        `<iframe title="Q3 &quot;revenue&quot; &lt;net&gt;" id="q3-revenue-net" height="400">\n` +
        `${OPENCLAW_WIDGET_COMPAT_PRELUDE}\n<div class="card">Q3</div>\n</iframe>`,
    })
    expect(close).toHaveBeenCalledTimes(1)
    expect(result).toEqual({
      ok: true,
      value: {
        kind: "message",
        receipt: {
          primaryPlatformMessageId: "901",
          platformMessageIds: ["901"],
          parts: [{ platformMessageId: "901", kind: "card", index: 0 }],
          sentAt: 1_700_000_000_000,
        },
      },
    })
  })

  it("rejects HTML containing </iframe without sending", async () => {
    const { presenter, sendMessage, createClient } = setup()
    const result = await presenter.present({
      document: { kind: "html", html: openClawDocument("<p>a</p>\n</iframe>\n<p>b</p>") },
      title: "Broken",
      context: inlineContext,
    })
    expect(result).toEqual({
      ok: false,
      error: { code: "presentation_error", message: expect.stringContaining("</iframe") },
    })
    expect(createClient).not.toHaveBeenCalled()
    expect(sendMessage).not.toHaveBeenCalled()
  })

  it("reports a server rejection as a presentation error", async () => {
    const { presenter, sendMessage, close } = setup()
    sendMessage.mockRejectedValueOnce(new Error("BAD_REQUEST: Widget HTML has `vh` units"))
    const result = await presenter.present({
      document: { kind: "html", html: "<div style=\"height:100vh\"></div>" },
      title: "Tall",
      context: inlineContext,
    })
    expect(result).toEqual({
      ok: false,
      error: { code: "presentation_error", message: expect.stringContaining("`vh` units") },
    })
    expect(close).toHaveBeenCalledTimes(1)
  })

  it("is unavailable when the Inline account is not configured", async () => {
    const presenter = createInlineWidgetPresenter({ readConfig: () => ({}) as OpenClawConfig })
    await expect(presenter.availability(inlineContext)).resolves.toMatchObject({
      ok: false,
      error: { code: "unavailable" },
    })
    const { presenter: configured } = setup()
    await expect(configured.availability(inlineContext)).resolves.toEqual({ ok: true, value: { available: true } })
  })

  it("registers only on hosts that support widget presenters", () => {
    const registerWidgetPresenter = vi.fn()
    expect(registerInlineWidgetPresenter({ config: cfg, registerWidgetPresenter } as never)).toBe(true)
    expect(registerWidgetPresenter).toHaveBeenCalledWith(expect.objectContaining({ target: "current_channel" }))
    expect(registerInlineWidgetPresenter({ config: cfg } as never)).toBe(false)
  })
})
