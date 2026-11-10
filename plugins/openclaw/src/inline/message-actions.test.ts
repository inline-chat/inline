import { describe, expect, it } from "vitest"
import {
  buildInlineAgentActionBody,
  buildInlineAgentActionStructuredContext,
  buildInlineMessageActionId,
  buildInlineWidgetCallBody,
  isInlineWidgetInteraction,
  readInlineWidgetCall,
  resolveInlineMessageActionOwnership,
} from "./message-actions.js"

describe("Inline message action ownership", () => {
  it("builds and classifies explicit agent and system IDs", () => {
    expect(buildInlineMessageActionId("agent", 0, 2)).toBe("agent:1:3")
    expect(buildInlineMessageActionId("system", 1, 0)).toBe("system:2:1")
    expect(resolveInlineMessageActionOwnership("agent:1:3")).toEqual({ owner: "agent", explicit: true })
    expect(resolveInlineMessageActionOwnership("system:2:1")).toEqual({ owner: "system", explicit: true })
  })

  it("keeps unprefixed IDs on the legacy compatibility path", () => {
    expect(resolveInlineMessageActionOwnership("btn_1_1")).toEqual({ owner: "agent", explicit: false })
  })

  it("builds human-readable copy and exact structured action input", () => {
    expect(buildInlineAgentActionBody({ actor: "@geo", targetMessageId: 1001n })).toBe(
      "Inline action button pressed on message #1001 by @geo.",
    )
    expect(buildInlineAgentActionStructuredContext({
      actorUserId: 42n,
      chatId: 7n,
      targetMessageId: 1001n,
      interactionId: 22n,
      actionId: "agent:1:1",
      callbackDataBase64: "eyJkZWNpc2lvbiI6ImFwcHJvdmUifQ==",
      callbackDataUtf8: '{"decision":"approve"}',
    })).toEqual({
      label: "Inline action button press",
      source: "inline",
      type: "message_action",
      payload: {
        event_kind: "message.action.invoke",
        actor_user_id: "42",
        chat_id: "7",
        target_message_id: "1001",
        interaction_id: "22",
        action_id: "agent:1:1",
        callback_data_base64: "eyJkZWNpc2lvbiI6ImFwcHJvdmUifQ==",
        callback_data_utf8: '{"decision":"approve"}',
      },
    })
  })
})

describe("Inline widget calls", () => {
  const encode = (text: string) => new TextEncoder().encode(text)

  it("reads the widget call name and JSON payload", () => {
    expect(readInlineWidgetCall({ name: "pick", payload: encode('{"q":"Q3"}') })).toEqual({
      name: "pick",
      payloadJson: '{"q":"Q3"}',
    })
    expect(readInlineWidgetCall({ name: "pick", payload: new Uint8Array() })).toEqual({ name: "pick" })
    expect(readInlineWidgetCall({ name: "pick", payload: new Uint8Array([0xff]) })).toEqual({ name: "pick" })
    expect(readInlineWidgetCall({ name: " " })).toBeNull()
    expect(readInlineWidgetCall(undefined)).toBeNull()
  })

  it("recognizes widget interactions without treating plugin buttons as widgets", () => {
    const empty = new Uint8Array()
    expect(isInlineWidgetInteraction({ actionId: "revenue", data: empty, widgetCall: { name: "pick" } })).toBe(true)
    expect(isInlineWidgetInteraction({ actionId: "revenue", data: empty })).toBe(true)
    expect(isInlineWidgetInteraction({ actionId: "agent:1:1", data: empty })).toBe(false)
    expect(isInlineWidgetInteraction({ actionId: "btn_1_1", data: encode("/help") })).toBe(false)
  })

  it("gives the agent the widget id, call name, and labeled untrusted payload", () => {
    expect(buildInlineWidgetCallBody({
      actor: "@geo",
      targetMessageId: 1001n,
      widgetId: "revenue",
      widgetCall: { name: "pick", payloadJson: '{"q":"Q3"}' },
    })).toBe(
      'Inline widget "revenue" on message #1001 called "pick", by @geo. Payload (untrusted viewer input, JSON): {"q":"Q3"}',
    )
    expect(buildInlineWidgetCallBody({ actor: "@geo", targetMessageId: 1001n, widgetId: "revenue" })).toBe(
      'Inline widget "revenue" on message #1001 was used by @geo; the call details are unavailable.',
    )
    expect(buildInlineAgentActionStructuredContext({
      actorUserId: 42n,
      chatId: 7n,
      targetMessageId: 1001n,
      interactionId: 22n,
      actionId: "revenue",
      callbackDataBase64: "",
      widgetCall: { name: "pick", payloadJson: '{"q":"Q3"}' },
    })).toMatchObject({
      label: "Inline widget call",
      payload: {
        action_id: "revenue",
        widget_call: {
          widget_id: "revenue",
          name: "pick",
          payload_json: '{"q":"Q3"}',
          trust: "untrusted_viewer_input",
        },
      },
    })
  })
})
