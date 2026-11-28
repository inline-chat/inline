import { describe, expect, it } from "vitest"
import { BotChatSettingsResponse, MessageActionResponseUi } from "@inline-chat/protocol/core"
import { InlineResponseUi } from "./response-ui.js"

describe("InlineResponseUi", () => {
  it("builds an open_url answer that survives the wire", () => {
    const ui = InlineResponseUi.openUrl("http://127.0.0.1:18789/#bootstrapToken=abc", {
      sensitive: true,
      hostLabel: "Mo's MacBook Pro",
      unreachableText: "Turn on Tailscale Serve.",
    })
    const decoded = MessageActionResponseUi.fromBinary(MessageActionResponseUi.toBinary(ui))
    expect(decoded).toEqual(ui)
  })

  it("rides on a settings answer beside the document", () => {
    const response = BotChatSettingsResponse.fromBinary(BotChatSettingsResponse.toBinary({
      result: { oneofKind: "problem", problem: { code: 4, message: "Dashboard is off" } },
      ui: InlineResponseUi.alert("Run hermes dashboard first.", "Dashboard isn't running"),
    }))
    expect(response.ui?.kind).toEqual({
      oneofKind: "alert",
      alert: { text: "Run hermes dashboard first.", title: "Dashboard isn't running" },
    })
  })

  it("leaves optional fields out of plain links and toasts", () => {
    expect(InlineResponseUi.openUrl("https://example.com/")).toEqual({
      kind: { oneofKind: "openUrl", openUrl: { url: "https://example.com/", sensitive: false } },
    })
    expect(InlineResponseUi.toast("Saved")).toEqual({ kind: { oneofKind: "toast", toast: { text: "Saved" } } })
  })
})
