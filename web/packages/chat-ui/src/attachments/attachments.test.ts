import type { ExternalTaskAttachment, MessageActionButton, MessageActionRows, PhotoInfo, UrlPreviewAttachment } from "@inline/core-protocol"
import type { InlineID, PhotoID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { buttonRowsModel, buttonsById, grantReason, unavailableActionText } from "./buttons"
import { externalTaskHeadline, externalTaskModel } from "./external-task"
import { attachmentModels } from "./model"
import { largePreviewMediaHeight, urlPreviewModel } from "./url-preview"

const id = "1" as InlineID
const photo: PhotoInfo = { id: "9" as PhotoID, sizes: [{ type: "c", width: 320, height: 160, cdnUrl: "https://cdn/c" }] }

const preview = (extra: Partial<UrlPreviewAttachment>): UrlPreviewAttachment => ({ kind: "urlPreview", id, ...extra })

const adversarial = [
  "javascript:alert(1)",
  "JaVaScRiPt:alert(1)",
  "java\tscript:alert(1)",
  "data:text/html,<script>alert(1)</script>",
  "vbscript:msgbox(1)",
  "file:///etc/passwd",
  "https://user:pass@example.com/",
  "https://exa‮mple.com/",
  "//evil.example/",
  "blob:https://example.com/1",
]

describe("URL previews", () => {
  it("falls back for title and source like the Mac", () => {
    const model = urlPreviewModel(preview({ url: "https://www.Example.com/a", description: "About" }))
    expect(model).toMatchObject({
      layout: "compact",
      title: "example.com",
      source: "example.com",
      subtitle: "About",
      link: { kind: "web", href: "https://www.example.com/a" },
    })
    const named = urlPreviewModel(preview({ url: "https://youtu.be/x", provider: "youtube", title: "Talk", duration: 75, mediaType: "video" }))
    expect(named.source).toBe("YouTube")
    expect(named.subtitle).toBe("YouTube • 1:15")
  })

  it("chooses large or compact from the layout hints", () => {
    expect(urlPreviewModel(preview({ url: "https://a.example", photo, layout: { hasLargeMedia: true, showLargeMedia: true } })).layout).toBe("large")
    expect(urlPreviewModel(preview({ url: "https://a.example", photo, layout: { hasLargeMedia: false, showLargeMedia: true } })).layout).toBe("compact")
    expect(urlPreviewModel(preview({ url: "https://a.example", photo, layout: { hasLargeMedia: false, showLargeMedia: false } })).layout).toBe("compact")
    expect(urlPreviewModel(preview({ url: "https://a.example", photo, mediaType: "video" })).layout).toBe("large")
    expect(urlPreviewModel(preview({ url: "https://a.example", photo })).layout).toBe("compact")
    const large = urlPreviewModel(preview({ url: "https://a.example", photo, mediaType: "video" }))
    expect(large.media?.aspect).toBe(2)
    expect(large.media && largePreviewMediaHeight(large.media, 260)).toBe(130)
  })

  it("caps descriptions at 110 (compact) or 420 (large) characters", () => {
    const long = "x".repeat(500)
    expect(urlPreviewModel(preview({ url: "https://a.example", description: long })).description).toBe(`${"x".repeat(110)}...`)
    expect(
      urlPreviewModel(preview({ url: "https://a.example", description: long, photo, layout: { hasLargeMedia: true, showLargeMedia: true } }))
        .description,
    ).toBe(`${"x".repeat(420)}...`)
  })

  it("never links an unsafe URL, and never plays an unsafe stream", () => {
    for (const url of adversarial) {
      const model = urlPreviewModel(
        preview({
          url,
          title: "T",
          photo,
          layout: { hasLargeMedia: true, showLargeMedia: true },
          media: { kind: "externalVideo", url },
        }),
      )
      expect(model.link, url).toBeUndefined()
      expect(model.media?.stream, url).toBeUndefined()
      // Text stays text.
      expect(model.title).toBe("T")
    }
    // App and mail links are not web links: the card does not open them.
    expect(urlPreviewModel(preview({ url: "inline://chat/5" })).link).toBeUndefined()
    expect(urlPreviewModel(preview({ url: "mailto:a@b.c" })).link).toBeUndefined()
  })

  it("uses the X style without a title", () => {
    const model = urlPreviewModel(preview({ url: "https://x.com/a/1", provider: "x", title: "ignored", description: "post", author: "Ada" }))
    expect(model).toMatchObject({ style: "x", title: undefined, description: "post", author: { name: "Ada" } })
  })
})

describe("external tasks", () => {
  const task = (extra: Partial<ExternalTaskAttachment>): ExternalTaskAttachment => ({
    kind: "externalTask",
    id,
    taskId: "LIN-1",
    application: "Linear",
    title: "",
    url: "https://linear.app/x",
    ...extra,
  })

  it("words the headline like the Mac", () => {
    const linear = externalTaskModel(task({ assigneeUserId: "7" as UserID }))
    expect(externalTaskHeadline(linear, "Ada")).toBe("Ada created a Linear issue")
    expect(linear.title).toBe("Untitled")
    expect(externalTaskHeadline(externalTaskModel(task({ application: "notion", assigneeUserId: "7" as UserID })), "Ada")).toBe(
      "Ada will do",
    )
    expect(externalTaskHeadline(externalTaskModel(task({})), "Ada")).toBe("Unassigned")
    expect(externalTaskModel(task({ url: "javascript:alert(1)" })).link).toBeUndefined()
  })

  it("maps a row's attachments in order, skipping unknown kinds", () => {
    const models = attachmentModels({
      attachments: [preview({ url: "https://a.example" }), { kind: "unknown", id }, task({})],
    })
    expect(models.map((model) => model.kind)).toEqual(["urlPreview", "externalTask"])
  })
})

describe("bot buttons", () => {
  const button = (actionId: string, action: MessageActionButton["action"], extra: Partial<MessageActionButton> = {}): MessageActionButton => ({
    actionId,
    text: actionId,
    style: "default",
    action,
    ...extra,
  })

  it("resolves behaviors and refuses unsafe URLs", () => {
    const rows: MessageActionRows = [
      [
        button("cb", { kind: "callback" }, { style: "primary", confirm: { title: "" } }),
        button("copy", { kind: "copyText", text: "abc" }),
      ],
      [button("web", { kind: "openUrl", url: "https://example.com" }), button("app", { kind: "openUrl", url: "inline://chat/5" })],
      [button("compose", { kind: "compose", text: "  hi  " }), button("empty", { kind: "compose", text: "   " })],
      [button("unknown", { kind: "unknown" })],
    ]
    const model = buttonRowsModel(rows)
    const behaviors = model.rows.flat().map((item) => [item.actionId, item.behavior.kind])
    expect(behaviors).toEqual([
      ["cb", "callback"],
      ["copy", "copy"],
      ["web", "openUrl"],
      ["app", "openUrl"],
      ["compose", "compose"],
      ["empty", "unavailable"],
      ["unknown", "unavailable"],
    ])
    expect(model.rows[0]?.[0]?.confirm).toEqual({ title: "cb", text: undefined, confirmLabel: "cb" })
    expect(model.rows[2]?.[0]?.behavior).toEqual({ kind: "compose", text: "hi" })

    for (const url of [...adversarial, "codex://threads/1", "ftp://example.com"]) {
      const [only] = buttonRowsModel([[button("x", { kind: "openUrl", url })]]).rows.flat()
      expect(only?.behavior, url).toEqual({ kind: "unavailable", reason: unavailableActionText })
    }
  })

  it("leaves claimed buttons out and drops empty rows", () => {
    const rows: MessageActionRows = [[button("a", { kind: "callback" })], [button("b", { kind: "callback" })]]
    expect(buttonRowsModel(rows, new Set(["a"])).rows.map((row) => row.map((item) => item.actionId))).toEqual([["b"]])
  })

  it("picks card buttons by ID, deduplicated and labelled", () => {
    const rows: MessageActionRows = [[button("a", { kind: "callback" }), button("b", { kind: "callback" }, { text: " " })]]
    expect(buttonsById(rows, ["a", "missing", "a", "b"]).map((item) => item.actionId)).toEqual(["a"])
  })

  it("words grant reasons like the Mac", () => {
    expect(grantReason("approve")).toBe("Only the agent’s owner can approve")
    expect(grantReason("invoke", { owner: "Ada", agent: "Scout" })).toBe("Ask Ada for access to Scout")
    expect(grantReason("access")).toBe("Only people with access to this agent can answer")
    expect(grantReason("steer", { owner: "Ada" })).toBe("Only Ada and people they allow can steer this agent")
    expect(grantReason("owner")).toBe("Only the agent’s owner can change this")
    expect(grantReason("unknown")).toBe("You can’t use this")
  })
})
