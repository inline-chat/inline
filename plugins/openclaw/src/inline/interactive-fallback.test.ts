import { describe, expect, it } from "vitest"
import {
  normalizeInlineLegacyInteractivePresentation,
  resolveInlineInteractiveTextFallback,
} from "./interactive-fallback"

describe("inline/interactive-fallback", () => {
  it("combines authored text with canonical presentation content", () => {
    expect(
      resolveInlineInteractiveTextFallback({
        text: "Pick one",
        interactive: { blocks: [{ type: "text", text: "Legacy" }] },
        presentation: { blocks: [{ type: "text", text: "Presentation" }] },
      }),
    ).toBe("Pick one\n\nPresentation")
  })

  it("prefers canonical presentation over legacy interactive content", () => {
    expect(
      resolveInlineInteractiveTextFallback({
        text: " ",
        interactive: {
          blocks: [
            { type: "text", text: " First " },
            { type: "buttons", buttons: [{ label: "Approve", value: "approve" }] },
            { type: "text", text: "Second" },
          ],
        },
        presentation: { blocks: [{ type: "text", text: "Presentation" }] },
      }),
    ).toBe("Presentation")
  })

  it("renders presentation fallback text when text is omitted", () => {
    expect(
      resolveInlineInteractiveTextFallback({
        presentation: {
          title: "Deploy",
          blocks: [
            { type: "context", text: "Build 12" },
            {
              type: "buttons",
              buttons: [
                { label: "Approve", action: { type: "callback", value: "deploy:approve" } },
                { label: "Status", action: { type: "command", command: "/status" } },
              ],
            },
          ],
        },
      }),
    ).toBe("Deploy\n\nBuild 12\n\n- Approve\n- Status: `/status`")
  })

  it("falls back to legacy button labels when nothing else renders", () => {
    expect(
      resolveInlineInteractiveTextFallback({
        interactive: {
          blocks: [{ type: "buttons", buttons: [{ label: "Approve", value: "approve" }] }],
        },
      }),
    ).toBe("- Approve")
  })

  it("keeps unsupported URL controls visible beside authored text", () => {
    const text = resolveInlineInteractiveTextFallback({
      text: "Read the docs",
      presentation: {
        blocks: [{ type: "buttons", buttons: [{ label: "Docs", action: { type: "url", url: "https://inline.chat/docs" } }] }],
      },
    })
    expect(text).toBe("Read the docs\n\n- Docs: https://inline.chat/docs")
  })

  it("honors an explicitly authored presentation fallback", () => {
    expect(resolveInlineInteractiveTextFallback({
      text: "Readable fallback",
      presentationTextMode: "fallback",
      presentation: { blocks: [{ type: "text", text: "Native content" }] },
    })).toBe("Readable fallback")
  })

  it("returns the original text when there is nothing to render", () => {
    expect(resolveInlineInteractiveTextFallback({ text: "" })).toBe("")
    expect(resolveInlineInteractiveTextFallback({ text: null })).toBeUndefined()
    expect(resolveInlineInteractiveTextFallback({ interactive: { blocks: [] } })).toBeUndefined()
  })

  it("normalizes only legacy block kinds from interactive input", () => {
    expect(
      normalizeInlineLegacyInteractivePresentation({
        title: "Ignored",
        blocks: [
          { type: "context", text: "Ignored" },
          { type: "text", text: "Kept" },
          { type: "buttons", buttons: [{ label: "Go", action: { type: "callback", value: "go" } }] },
          { type: "select", options: [{ label: "A", value: "a" }] },
        ],
      }),
    ).toEqual({
      blocks: [
        { type: "text", text: "Kept" },
        {
          type: "buttons",
          buttons: [{ label: "Go", action: { type: "callback", value: "go" }, style: undefined }],
        },
        { type: "select", placeholder: undefined, options: [{ label: "A", value: "a" }] },
      ],
    })
    expect(normalizeInlineLegacyInteractivePresentation({ blocks: [{ type: "divider" }] })).toBeUndefined()
    expect(normalizeInlineLegacyInteractivePresentation("nope")).toBeUndefined()
  })
})
