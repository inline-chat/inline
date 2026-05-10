import { describe, expect, it } from "vitest"
import { sanitizeInlineVisibleLabel, sanitizeInlineVisibleText } from "./outbound-sanitize"

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
})
