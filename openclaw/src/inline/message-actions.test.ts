import { describe, expect, it } from "vitest"
import {
  buildInlineAgentActionBody,
  buildInlineAgentActionStructuredContext,
  buildInlineMessageActionId,
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
