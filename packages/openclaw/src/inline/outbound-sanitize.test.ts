import { describe, expect, it } from "vitest"
import {
  INLINE_ACTION_CALLBACK_DATA_MAX_BYTES,
  INLINE_ACTION_LABEL_MAX_LENGTH,
  sanitizeInlineActionCallbackData,
  sanitizeInlineActionLabel,
  sanitizeInlineVisibleLabel,
  sanitizeInlineVisibleText,
} from "./outbound-sanitize"

const RUNTIME_NOTICE =
  "This context is runtime-generated, not user-authored. Keep internal details private."
const HEARTBEAT_CONTEXT = [
  "OpenClaw runtime context for the immediately preceding user message.",
  RUNTIME_NOTICE,
  "",
  "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly.",
  "If nothing needs attention, reply HEARTBEAT_OK.",
].join("\n")

describe("inline/outbound-sanitize", () => {
  it("suppresses copied OpenClaw heartbeat context", () => {
    expect(sanitizeInlineVisibleText(HEARTBEAT_CONTEXT)).toMatchObject({
      text: "",
      shouldSkip: true,
      didStrip: true,
    })
  })

  it("strips delimited OpenClaw runtime context and keeps visible text", () => {
    const text = [
      "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>",
      "private context",
      "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>",
      "Visible reply.",
    ].join("\n")

    expect(sanitizeInlineVisibleText(text)).toMatchObject({
      text: "Visible reply.",
      shouldSkip: false,
      didStrip: true,
    })
  })

  it("strips nested OpenClaw runtime context blocks and keeps surrounding text", () => {
    const text = [
      "Visible intro.",
      "",
      "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>",
      "outer context",
      "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>",
      "nested context",
      "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>",
      "outer tail",
      "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>",
      "",
      "Visible outro.",
    ].join("\n")

    expect(sanitizeInlineVisibleText(text)).toMatchObject({
      text: "Visible intro.\n\nVisible outro.",
      shouldSkip: false,
      didStrip: true,
    })
  })

  it("preserves inline mentions of OpenClaw runtime context markers", () => {
    const text =
      "The marker <<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>> is documented here, not a block."

    expect(sanitizeInlineVisibleText(text)).toEqual({
      text,
      shouldSkip: false,
      didStrip: false,
    })
  })

  it("strips current OpenClaw runtime event preface and keeps visible text", () => {
    const text = [
      "OpenClaw runtime event.",
      RUNTIME_NOTICE,
      "",
      "Visible event summary.",
    ].join("\n")

    expect(sanitizeInlineVisibleText(text)).toMatchObject({
      text: "Visible event summary.",
      shouldSkip: false,
      didStrip: true,
    })
  })

  it("strips legacy OpenClaw runtime context preface and keeps visible text", () => {
    const text = [
      "OpenClaw runtime context (internal):",
      RUNTIME_NOTICE,
      "",
      "Visible legacy summary.",
    ].join("\n")

    expect(sanitizeInlineVisibleText(text)).toMatchObject({
      text: "Visible legacy summary.",
      shouldSkip: false,
      didStrip: true,
    })
  })

  it("strips legacy OpenClaw internal task events and keeps surrounding text", () => {
    const text = [
      "Visible intro.",
      "",
      "OpenClaw runtime context (internal):",
      RUNTIME_NOTICE,
      "",
      "[Internal task completion event]",
      "source: subagent",
      "<<<BEGIN_UNTRUSTED_CHILD_RESULT>>>",
      "private result",
      "<<<END_UNTRUSTED_CHILD_RESULT>>>",
      "",
      "Action:",
      "summarize",
      "",
      "Visible outro.",
    ].join("\n")

    expect(sanitizeInlineVisibleText(text)).toMatchObject({
      text: "Visible intro.\n\nVisible outro.",
      shouldSkip: false,
      didStrip: true,
    })
  })

  it("suppresses heartbeat ack payloads", () => {
    expect(sanitizeInlineVisibleText("**HEARTBEAT_OK**")).toMatchObject({
      text: "",
      shouldSkip: true,
      didStrip: true,
    })
  })

  it("preserves ordinary text that only mentions runtime context", () => {
    const text = "The phrase OpenClaw runtime context (internal): can be documented."
    expect(sanitizeInlineVisibleText(text)).toEqual({
      text,
      shouldSkip: false,
      didStrip: false,
    })
  })

  it("preserves ordinary text that documents HEARTBEAT_OK", () => {
    const text = "The HEARTBEAT_OK token is used for silent heartbeat acknowledgements."
    expect(sanitizeInlineVisibleText(text)).toEqual({
      text,
      shouldSkip: false,
      didStrip: false,
    })
  })

  it("drops unsafe button labels", () => {
    expect(sanitizeInlineVisibleLabel(HEARTBEAT_CONTEXT)).toBeNull()
    expect(sanitizeInlineVisibleLabel(" Approve ")).toBe("Approve")
  })

  it("keeps action button labels within Inline server limits", () => {
    expect(sanitizeInlineActionLabel(HEARTBEAT_CONTEXT)).toBeNull()
    expect(sanitizeInlineActionLabel("x".repeat(80))).toBe(
      `${"x".repeat(INLINE_ACTION_LABEL_MAX_LENGTH - 3)}...`,
    )
  })

  it("drops action callback data that exceeds Inline server limits", () => {
    expect(sanitizeInlineActionCallbackData(" approve ")).toBe("approve")
    expect(sanitizeInlineActionCallbackData("x".repeat(INLINE_ACTION_CALLBACK_DATA_MAX_BYTES))).toBe(
      "x".repeat(INLINE_ACTION_CALLBACK_DATA_MAX_BYTES),
    )
    expect(sanitizeInlineActionCallbackData("x".repeat(INLINE_ACTION_CALLBACK_DATA_MAX_BYTES + 1))).toBeNull()
  })
})
