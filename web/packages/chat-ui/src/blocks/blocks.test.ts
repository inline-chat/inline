import type { ContentBlock, Entity, MessageActionRows, MessageRow, PhotoInfo, TextRange } from "@inline/core-protocol"
import type { PhotoID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { buildBlockTree, formatElapsed } from "./build"
import { beginSubmit, formButtonLabel, initialFormSession, setFormAnswer, submitFailed, submitSucceeded } from "./form"
import { changedRichBlockKeys, updateBlockTree } from "./reuse"
import type { BlockTree, FormBlock, RichBlock } from "./types"

type Input = Pick<MessageRow, "text" | "entities" | "blocks" | "actions" | "date">

/** The range of the `nth` occurrence of `needle` in `text`. */
const at = (text: string, needle: string, nth = 0): TextRange => {
  let index = -1
  for (let count = 0; count <= nth; count += 1) {
    index = text.indexOf(needle, index + 1)
    if (index < 0) throw new Error(`no ${needle}`)
  }
  return { offset: index, length: needle.length }
}

const input = (text: string, blocks: ContentBlock[], extra: Partial<Input> = {}): Input => ({ text, blocks, date: 1000, ...extra })

const tree = (text: string, blocks: ContentBlock[], extra: Partial<Input> = {}, now?: number): BlockTree => {
  const built = buildBlockTree(input(text, blocks, extra), now !== undefined ? { now } : {})
  if (!built) throw new Error("fell back to flat text")
  return built
}

const only = <K extends RichBlock["kind"]>(built: BlockTree, kind: K): Extract<RichBlock, { kind: K }> => {
  const found = built.blocks.find((block) => block.kind === kind)
  if (!found) throw new Error(`no ${kind} in ${built.blocks.map((block) => block.kind).join(",")}`)
  return found as Extract<RichBlock, { kind: K }>
}

const photo: PhotoInfo = {
  id: "5" as PhotoID,
  sizes: [{ type: "f", width: 1000, height: 500, cdnUrl: "https://cdn/f" }],
  stripped: new Uint8Array([1, 2, 2, 0]),
}

const actions: MessageActionRows = [
  [
    { actionId: "approve", text: "Approve", style: "primary", action: { kind: "callback" } },
    { actionId: "deny", text: "Deny", style: "destructive", action: { kind: "callback" } },
  ],
  [{ actionId: "other", text: "Other", style: "default", action: { kind: "callback" } }],
]

describe("block tree: every kind", () => {
  const text = [
    "Intro text", // paragraph
    "Title", // heading
    "let x = 1", // code
    "first", // list item
    "second", // list item
    "alt", // image alt
    "Working on it", // disclosure summary
    "inside", // disclosure child
    "quoted", // quote child
    "h1|h2|c1|c2", // table cells
    "E=mc^2", // math
    "src/a.ts", // diff path
    "@@ -1 +1 @@\n-a\n+b", // diff text
    "Command", // field label
    "rm -rf build", // field value
    "Step one", // step
    "Heads up", // callout title
    "callout body", // callout child
    "Context", // meter label
    "Pick", // form title
    "Color", // field label
    "Red", // option
    "Widget title", // widget title
    "The plan", // plan title
    "Run tests", // approval title
    "Review notes", // review title
    "bug here", // finding
    "Do the thing", // task
    "All done", // next step recap
    "Ship it", // prompt
    "footer note", // footer
  ].join("\n")
  const r = (needle: string, nth = 0) => at(text, needle, nth)
  const blocks: ContentBlock[] = [
    { kind: "paragraph", text: r("Intro text") },
    { kind: "heading", text: r("Title"), level: 9 },
    { kind: "code", text: r("let x = 1"), language: "ts" },
    {
      kind: "list",
      style: "ordered",
      start: 3,
      items: [
        { children: [{ kind: "paragraph", text: r("first") }] },
        { children: [{ kind: "paragraph", text: r("second") }], checked: true },
      ],
    },
    { kind: "separator" },
    { kind: "image", image: { state: "ready", photo, alt: r("alt") } },
    {
      kind: "album",
      images: [
        { state: "ready", photo },
        { state: "pending", width: 300, height: 300, stripped: new Uint8Array([1, 1, 1, 0]) },
        { state: "unavailable" },
      ],
    },
    {
      kind: "disclosure",
      summary: r("Working on it"),
      style: "progress",
      children: [{ kind: "paragraph", text: r("inside") }],
      activity: "command",
      status: "running",
    },
    { kind: "quote", children: [{ kind: "paragraph", text: r("quoted") }], rtl: true },
    {
      kind: "table",
      rows: [
        [r("h1"), r("h2")],
        [r("c1"), r("c2")],
      ],
      alignments: [undefined, "right"],
    },
    { kind: "math", text: r("E=mc^2") },
    { kind: "diff", path: r("src/a.ts"), text: r("@@ -1 +1 @@\n-a\n+b"), change: "added", additions: 1, deletions: 1 },
    { kind: "fields", fields: [{ label: r("Command"), value: r("rm -rf build"), monospace: true }] },
    { kind: "steps", steps: [{ text: r("Step one"), status: "done" }] },
    { kind: "callout", tone: "warning", title: r("Heads up"), children: [{ kind: "paragraph", text: r("callout body") }] },
    { kind: "meter", label: r("Context"), value: 150, max: 100, tone: "critical" },
    {
      kind: "form",
      formId: "f",
      title: r("Pick"),
      closed: false,
      fields: [
        {
          fieldId: "color",
          label: r("Color"),
          required: true,
          input: { kind: "select", options: [{ optionId: "red", label: r("Red"), recommended: true }], multiple: false, defaultOptionIds: ["red", "nope"], allowOther: false },
        },
      ],
    },
    { kind: "widget", widgetId: "w", title: r("Widget title"), htmlLength: 20, images: [] },
    { kind: "planProposal", title: r("The plan"), children: [], state: "pending", actionIds: ["approve", "deny"] },
    { kind: "approval", title: r("Run tests"), children: [], state: "accepted", actionIds: ["other"] },
    { kind: "review", title: r("Review notes"), verdict: "needsAttention", findings: [{ title: r("bug here"), priority: "p1", startLine: 3, endLine: 5 }] },
    { kind: "taskSuggestion", title: r("Do the thing"), state: "pending", actionIds: [] },
    { kind: "nextStep", recap: r("All done"), actionIds: [], blocking: true },
    { kind: "promptSuggestions", prompts: [{ label: r("Ship it") }] },
    { kind: "footer", text: r("footer note") },
  ]

  it("builds one node per block with the Mac's rules", () => {
    const built = tree(text, blocks, { actions })
    expect(built.blocks.map((block) => block.kind)).toEqual([
      "paragraph",
      "heading",
      "code",
      "list",
      "separator",
      "image",
      "album",
      "disclosure",
      "quote",
      "table",
      "math",
      "diff",
      "fields",
      "steps",
      "callout",
      "meter",
      "form",
      "widget",
      "planProposal",
      "approval",
      "review",
      "taskSuggestion",
      "nextStep",
      "promptSuggestions",
      "footer",
    ])
    expect(only(built, "paragraph").text.document.text).toBe("Intro text")
    expect(only(built, "heading").level).toBe(6)
    expect(only(built, "code")).toMatchObject({ language: "ts", code: "let x = 1" })
    expect(only(built, "list").items.map((item) => item.markerText)).toEqual(["3.", "☑"])
    expect(only(built, "image").image).toMatchObject({ state: "ready", alt: "alt", box: { width: 420, height: 210 } })
    expect(only(built, "image").image.preview?.[0]).toBe(0xff)
    expect(only(built, "album").images.map((image) => [image.state, image.box.width])).toEqual([
      ["ready", 220],
      ["pending", 126],
      ["unavailable", 168],
    ])
    expect(only(built, "disclosure")).toMatchObject({
      style: "progress",
      shimmer: true,
      statusBadge: undefined,
      timer: { startedAt: 1000 },
      initiallyOpen: false,
    })
    expect(only(built, "quote").dir).toBe("rtl")
    expect(only(built, "table").alignments).toEqual(["start", "right"])
    expect(only(built, "table").header.map((cell) => cell.text.document.text)).toEqual(["h1", "h2"])
    expect(only(built, "math").source).toBe("E=mc^2")
    expect(only(built, "diff").lines.map((line) => line.kind)).toEqual(["hunk", "delete", "add"])
    expect(only(built, "fields").fields[0]).toMatchObject({ code: "rm -rf build", value: undefined })
    expect(only(built, "steps")).toMatchObject({ card: true, steps: [{ status: "done" }] })
    expect(only(built, "callout").tone).toBe("warning")
    expect(only(built, "meter")).toMatchObject({ fraction: 1, tone: "critical" })
    expect(only(built, "form")).toMatchObject({ submitLabel: "Submit", fields: [{ labelText: "Color", input: { defaultOptionIds: ["red"], presentation: "list" } }] })
    expect(only(built, "widget")).toMatchObject({
      frame: { kind: "sandboxedFrame", origin: "separate", network: "none" },
      height: 240,
      maxInlineHeight: 720,
    })
    expect(only(built, "planProposal")).toMatchObject({ chip: "Awaiting approval", showButtons: true, note: undefined, defaultTitle: "Plan" })
    expect(only(built, "planProposal").buttons.map((button) => button.actionId)).toEqual(["approve", "deny"])
    expect(only(built, "approval")).toMatchObject({ chip: "Approved", note: "Approved", showButtons: false, buttons: [] })
    expect(only(built, "review")).toMatchObject({ chip: "1 finding", findings: [{ priorityLabel: "P1", lines: "3-5" }] })
    expect(only(built, "taskSuggestion")).toMatchObject({ chip: undefined, showButtons: false })
    expect(only(built, "nextStep")).toMatchObject({ chip: "Waiting on you", blocking: true })
    expect(only(built, "promptSuggestions").prompts[0]?.composeText).toBe("Ship it")
    // Only buttons a card draws are claimed; the decided approval claims none.
    expect(built.claimedActionIds).toEqual(["approve", "deny"])
  })

  it("keys blocks by kind and path", () => {
    const built = tree(text, blocks, { actions })
    expect(built.blocks.slice(0, 4).map((block) => block.key)).toEqual(["paragraph@0", "heading@1", "code@2", "list@3"])
    expect(only(built, "list").items.map((item) => item.children[0]?.key)).toEqual(["paragraph@3.0.0", "paragraph@3.1.0"])
    const keys = new Set<string>()
    const visit = (value: unknown) => {
      if (Array.isArray(value)) value.forEach(visit)
      else if (value && typeof value === "object" && !(value instanceof Uint8Array)) {
        const key = (value as { key?: unknown }).key
        if (typeof key === "string" && "kind" in value) {
          expect(keys.has(key), key).toBe(false)
          keys.add(key)
        }
        // Text documents have their own key space.
        for (const [name, child] of Object.entries(value)) if (name !== "document") visit(child)
      }
    }
    visit(built.blocks)
    expect(keys.size).toBeGreaterThan(30)
  })
})

describe("block text and entities", () => {
  it("clips the message's entities to each block's range", () => {
    const text = "Hello world\nSee docs now"
    const entities: Entity[] = [
      { type: "bold", offset: 6, length: 10 }, // "world\nSee "
      { type: "textUrl", offset: 16, length: 4, url: "https://example.com/docs" },
      { type: "url", offset: 0, length: 3, url: "javascript:alert(1)" },
    ]
    const built = tree(text, [{ kind: "paragraph", text: at(text, "Hello world") }, { kind: "heading", text: at(text, "See docs now"), level: 2 }], { entities })
    const first = only(built, "paragraph").text.document.blocks[0]
    expect(first?.kind === "paragraph" && first.children.map((child) => [child.kind, "marks" in child ? child.marks : undefined])).toEqual([
      ["text", []],
      ["text", ["bold"]],
    ])
    const heading = only(built, "heading").text
    expect(heading.start).toBe(12)
    const nodes = heading.document.blocks[0]?.kind === "paragraph" ? heading.document.blocks[0].children : []
    expect(nodes.map((node) => node.kind)).toEqual(["text", "link", "text"])
    const link = nodes[1]
    expect(link?.kind === "link" && link.link.kind === "web" && link.link.href).toBe("https://example.com/docs")
    expect(link?.start).toBe(4)
  })

  it("keeps code, math and monospace values literal", () => {
    const text = "**not bold**"
    const built = tree(text, [{ kind: "code", text: at(text, text) }], { entities: [{ type: "bold", offset: 0, length: 12 }] })
    expect(only(built, "code").code).toBe("**not bold**")
  })
})

describe("fallbacks", () => {
  it("shows the text an unknown kind covers, once per run", () => {
    const text = "Before\nmystery one\nmystery two\nAfter"
    const built = tree(text, [
      { kind: "paragraph", text: at(text, "Before") },
      { kind: "unknown" },
      { kind: "unknown" },
      { kind: "paragraph", text: at(text, "After") },
    ])
    expect(built.blocks.map((block) => block.kind)).toEqual(["paragraph", "fallback", "paragraph"])
    expect(only(built, "fallback").text.document.text).toBe("mystery one\nmystery two")
    expect(only(built, "fallback").key).toBe("fallback@1")
  })

  it("falls back inside a container to the gap after its header", () => {
    const text = "Summary\nchild text\nunknown child"
    const built = tree(text, [
      {
        kind: "disclosure",
        summary: at(text, "Summary"),
        style: "default",
        initiallyOpen: true,
        children: [{ kind: "paragraph", text: at(text, "child text") }, { kind: "unknown" }],
      },
    ])
    const disclosure = only(built, "disclosure")
    expect(disclosure.children.map((child) => child.kind)).toEqual(["paragraph", "fallback"])
    expect(disclosure.children[1]?.kind === "fallback" && disclosure.children[1].text.document.text).toBe("unknown child")
  })

  it("falls back for malformed ranges and out-of-bounds counts", () => {
    const text = "ok 😀 tail"
    const emoji = text.indexOf("😀")
    const cases: ContentBlock[] = [
      { kind: "paragraph", text: { offset: 0, length: 999 } },
      { kind: "paragraph", text: { offset: emoji + 1, length: 2 } },
      { kind: "heading", level: 1 },
      { kind: "list", style: "ordered", start: 1_000_000_000, items: [{ children: [] }] },
      { kind: "list", items: [{ children: [] }] },
      { kind: "table", rows: [[{ offset: 0, length: 1 }], [{ offset: 0, length: 1 }, { offset: 1, length: 1 }]], alignments: [] },
      { kind: "meter", label: { offset: 0, length: 2 }, value: 1, max: 0 },
      { kind: "album", images: [] },
      { kind: "quote", children: [] },
      { kind: "steps", steps: [] },
      { kind: "promptSuggestions", prompts: [] },
      { kind: "form", formId: "", fields: [], closed: false },
      { kind: "math", text: { offset: 0, length: 0 } },
    ]
    for (const block of cases) {
      const built = tree(text, [block])
      expect(built.blocks.map((node) => node.kind), JSON.stringify(block)).toEqual(["fallback"])
      expect(built.blocks[0]?.kind === "fallback" && built.blocks[0].text.document.text.length).toBeGreaterThan(0)
    }
  })

  it("renders the whole message as flat text past the Mac's limits", () => {
    let deep: ContentBlock = { kind: "paragraph", text: { offset: 0, length: 1 } }
    for (let depth = 0; depth < 16; depth += 1) deep = { kind: "quote", children: [deep] }
    expect(buildBlockTree(input("x", [deep]))).toBeUndefined()
    let fits: ContentBlock = { kind: "paragraph", text: { offset: 0, length: 1 } }
    for (let depth = 0; depth < 15; depth += 1) fits = { kind: "quote", children: [fits] }
    expect(buildBlockTree(input("x", [fits]))).toBeDefined()
    expect(buildBlockTree(input("x", Array.from({ length: 1025 }, () => ({ kind: "separator" }) as ContentBlock)))).toBeUndefined()
    const cells = Array.from({ length: 17 }, () => Array.from({ length: 16 }, () => ({ offset: 0, length: 1 })))
    expect(buildBlockTree(input("x", [{ kind: "table", rows: cells, alignments: [] }]))).toBeUndefined()
    expect(buildBlockTree(input("x", []))).toBeUndefined()
    expect(buildBlockTree({ text: "x", date: 0 })).toBeUndefined()
  })

  it("shows only the first widget; later ones fall back to their title", () => {
    const text = "One\nTwo"
    const built = tree(text, [
      { kind: "widget", widgetId: "a", title: at(text, "One"), htmlLength: 5, height: 5000, images: [] },
      { kind: "widget", widgetId: "b", title: at(text, "Two"), htmlLength: 5, images: [] },
    ])
    expect(built.blocks.map((block) => block.kind)).toEqual(["widget", "fallback"])
    expect(only(built, "widget").height).toBe(2000)
  })
})

describe("agent cards", () => {
  const text = "Plan\nTask\nRecap\nfinding"
  const r = (needle: string) => at(text, needle)

  it("words chips and notes by state", () => {
    const states = ["pending", "accepted", "declined", "expired", "superseded"] as const
    const plan = states.map((state) => {
      const node = only(tree(text, [{ kind: "planProposal", title: r("Plan"), children: [], state, actionIds: [] }]), "planProposal")
      return [node.chip, node.note]
    })
    expect(plan).toEqual([
      ["Awaiting approval", undefined],
      ["Approved", "Approved"],
      ["Kept planning", "Kept planning"],
      ["Expired", "Expired"],
      ["Replaced", "Replaced by a newer request"],
    ])
    const approval = states.map(
      (state) => only(tree(text, [{ kind: "approval", title: r("Plan"), children: [], state, actionIds: [] }]), "approval").chip,
    )
    expect(approval).toEqual(["Needs approval", "Approved", "Denied", "Expired", "Replaced"])
    const task = states.map(
      (state) => only(tree(text, [{ kind: "taskSuggestion", title: r("Task"), state, actionIds: [] }]), "taskSuggestion").chip,
    )
    expect(task).toEqual([undefined, "Started", "Dismissed", "Expired", "Replaced"])
  })

  it("expires open task suggestions and offers the started thread", () => {
    const expiring: ContentBlock = { kind: "taskSuggestion", title: r("Task"), state: "pending", expiresAt: 500, actionIds: ["approve"] }
    expect(only(tree(text, [expiring], { actions }, 600), "taskSuggestion")).toMatchObject({ state: "expired", showButtons: false })
    expect(only(tree(text, [expiring], { actions }, 400), "taskSuggestion")).toMatchObject({ state: "pending", showButtons: true })
    const started = only(
      tree(text, [{ kind: "taskSuggestion", title: r("Task"), state: "accepted", startedPeer: { kind: "user", userId: "3" as UserID }, actionIds: [] }]),
      "taskSuggestion",
    )
    expect(started.openThread).toEqual({ kind: "user", userId: "3" })
  })

  it("does not claim buttons of a card in a closed disclosure, or of a card that fell back", () => {
    const card: ContentBlock = { kind: "nextStep", recap: r("Recap"), actionIds: ["approve"], blocking: false }
    const closed = tree(text, [{ kind: "disclosure", summary: r("Plan"), style: "default", children: [card] }], { actions })
    expect(closed.claimedActionIds).toEqual([])
    const open = buildBlockTree(input(text, [{ kind: "disclosure", summary: r("Plan"), style: "default", children: [card] }], { actions }), {
      openDisclosures: new Map([["disclosure@0", true]]),
    })
    expect(open?.claimedActionIds).toEqual(["approve"])
    const broken = tree(text, [{ kind: "planProposal", title: { offset: 0, length: 0 }, children: [], state: "pending", actionIds: ["approve"] }], { actions })
    expect(broken.blocks.map((block) => block.kind)).toEqual(["fallback"])
    expect(broken.claimedActionIds).toEqual([])
  })

  it("words review chips", () => {
    const chip = (verdict: "correct" | undefined, count: number) =>
      only(
        tree(text, [{ kind: "review", verdict, findings: Array.from({ length: count }, () => ({ title: r("finding") })) }]),
        "review",
      ).chip
    expect([chip("correct", 0), chip(undefined, 0), chip(undefined, 1), chip(undefined, 3)]).toEqual([
      "Looks good",
      "No findings",
      "1 finding",
      "3 findings",
    ])
  })

  it("formats the working timer", () => {
    expect([formatElapsed(0, 8), formatElapsed(0, 64), formatElapsed(0, 3720), formatElapsed(0, 13 * 3600), formatElapsed(10, 5)]).toEqual([
      "8s",
      "1m 4s",
      "1h 2m",
      undefined,
      undefined,
    ])
  })
})

describe("forms", () => {
  const text = "Setup\nName\nToken\nNotify\nCount\nPick\nA\nB\nC\nD\nE\nF\nG"
  const r = (needle: string) => at(text, needle)
  const formBlock = (extra: Partial<Extract<ContentBlock, { kind: "form" }>> = {}): Extract<ContentBlock, { kind: "form" }> => ({
    kind: "form",
    formId: "setup",
    title: r("Setup"),
    closed: false,
    fields: [
      { fieldId: "name", label: r("Name"), required: true, input: { kind: "text", style: "singleLine", defaultValue: "Ada", maxLength: 5 } },
      { fieldId: "token", label: r("Token"), required: false, input: { kind: "text", style: "secret", defaultValue: "should-not-show" } },
      { fieldId: "notify", label: r("Notify"), required: false, input: { kind: "toggle", defaultValue: false } },
      { fieldId: "count", label: r("Count"), required: false, input: { kind: "number", integer: true, step: 0 } },
      {
        fieldId: "pick",
        label: r("Pick"),
        required: false,
        input: {
          kind: "select",
          options: ["A", "B", "C", "D", "E", "F", "G"].map((letter) => ({ optionId: letter, label: r(letter), recommended: false })),
          multiple: false,
          defaultOptionIds: [],
          allowOther: false,
        },
      },
    ],
    ...extra,
  })
  const build = (extra?: Partial<Extract<ContentBlock, { kind: "form" }>>): FormBlock => only(tree(text, [formBlock(extra)]), "form")

  it("never carries a secret default and uses a menu for long single choices", () => {
    const form = build()
    expect(form.fields[1]?.input).toEqual({ kind: "text", style: "secret", placeholder: undefined, defaultValue: undefined, maxLength: undefined })
    expect(form.fields[3]?.input).toMatchObject({ kind: "number", step: 1 })
    expect(form.fields[4]?.input).toMatchObject({ presentation: "menu" })
    expect(JSON.stringify(form)).not.toContain("should-not-show")
  })

  it("falls back for duplicate fields or options", () => {
    const duplicate = formBlock()
    const fields = [...duplicate.fields, duplicate.fields[0]!]
    expect(tree(text, [{ ...duplicate, fields }]).blocks[0]?.kind).toBe("fallback")
    const options = [
      { optionId: "A", label: r("A"), recommended: false },
      { optionId: "A", label: r("B"), recommended: false },
    ]
    const select = formBlock({
      fields: [{ fieldId: "x", label: r("Pick"), required: false, input: { kind: "select", options, multiple: true, defaultOptionIds: [], allowOther: false } }],
    })
    expect(tree(text, [select]).blocks[0]?.kind).toBe("fallback")
  })

  it("submits once, checks required fields, sends toggles always and forgets secrets", () => {
    const form = build()
    let session = initialFormSession(form)
    expect(session.answers.name).toEqual({ kind: "text", value: "Ada" })
    expect(session.answers.token).toEqual({ kind: "text", value: "" })
    session = setFormAnswer(form, session, "name", { kind: "text", value: "" })
    const blocked = beginSubmit(form, session)
    expect(blocked).toMatchObject({ ok: false, error: "Answer “Name” first" })
    session = setFormAnswer(form, session, "name", { kind: "text", value: "Grace Hopper" })
    expect(session.answers.name).toEqual({ kind: "text", value: "Grace" })
    session = setFormAnswer(form, session, "token", { kind: "text", value: "s3cret" })
    const started = beginSubmit(form, session)
    expect(started.ok).toBe(true)
    if (!started.ok) return
    expect(started.values).toEqual([
      { fieldId: "name", value: { kind: "text", text: "Grace" } },
      { fieldId: "token", value: { kind: "text", text: "s3cret" } },
      { fieldId: "notify", value: { kind: "toggle", value: false } },
    ])
    // The one-submit rule: no second submit while submitting, nor after.
    expect(beginSubmit(form, started.session)).toEqual({ ok: false, session: started.session })
    expect(setFormAnswer(form, started.session, "name", { kind: "text", value: "x" })).toBe(started.session)
    expect(submitFailed(started.session).phase).toBe("editing")
    const done = submitSucceeded(form, started.session)
    expect(done.phase).toBe("submitted")
    expect(done.answers.token).toEqual({ kind: "text", value: "" })
    expect(JSON.stringify(done)).not.toContain("s3cret")
    expect(beginSubmit(form, done).ok).toBe(false)
    expect(formButtonLabel(form, done)).toBe("Sent")
  })

  it("locks a closed form", () => {
    const form = build({ closed: true })
    const session = initialFormSession(form)
    expect(session.phase).toBe("submitted")
    expect(beginSubmit(form, session).ok).toBe(false)
    expect(formButtonLabel(form, session)).toBe("Answered")
  })
})

describe("streaming", () => {
  const blocksFor = (text: string): ContentBlock[] => {
    const lines = text.split("\n")
    let offset = 0
    return lines.map((line) => {
      const block: ContentBlock = { kind: "paragraph", text: { offset, length: line.length } }
      offset += line.length + 1
      return block
    })
  }

  it("appending to the last block keeps every earlier block's identity", () => {
    const first = "Para one\nPara two\nGrowing"
    const prev = updateBlockTree(undefined, input(first, blocksFor(first)))
    const nextText = `${first} more words`
    const next = updateBlockTree(prev, input(nextText, blocksFor(nextText)))
    expect(changedRichBlockKeys(prev, next)).toEqual(["paragraph@2"])
    expect(next?.blocks[0]).toBe(prev?.blocks[0])
    expect(next?.blocks[1]).toBe(prev?.blocks[1])
  })

  it("adding a block keeps the earlier ones", () => {
    const first = "One\nTwo"
    const prev = updateBlockTree(undefined, input(first, blocksFor(first)))
    const nextText = `${first}\nThree`
    const next = updateBlockTree(prev, input(nextText, blocksFor(nextText)))
    expect(changedRichBlockKeys(prev, next)).toEqual(["paragraph@2"])
  })

  it("returns the same tree for the same row content, and reuses equal bytes", () => {
    const text = "img"
    const blocks: ContentBlock[] = [{ kind: "image", image: { state: "ready", photo, alt: { offset: 0, length: 3 } } }]
    const row = input(text, blocks)
    const prev = updateBlockTree(undefined, row)
    expect(updateBlockTree(prev, row)).toBe(prev)
    // A structured-cloned copy of the same row (fresh byte arrays) reuses everything.
    expect(updateBlockTree(prev, structuredClone(row))).toBe(prev)
  })

  it("a status change on a step touches only that block", () => {
    const text = "Intro\nStep"
    const make = (status: "running" | "done"): ContentBlock[] => [
      { kind: "paragraph", text: at(text, "Intro") },
      { kind: "steps", steps: [{ text: at(text, "Step"), status }] },
    ]
    const prev = updateBlockTree(undefined, input(text, make("running")))
    const next = updateBlockTree(prev, input(text, make("done")))
    expect(changedRichBlockKeys(prev, next)).toEqual(["steps@1"])
  })
})

describe("streaming with options", () => {
  const text = "Intro\nFirst\nRecap\nSecond\nimg"
  const blocks: ContentBlock[] = [
    { kind: "paragraph", text: at(text, "Intro") },
    {
      kind: "disclosure",
      summary: at(text, "First"),
      style: "default",
      children: [{ kind: "nextStep", recap: at(text, "Recap"), actionIds: ["approve"], blocking: false }],
    },
    { kind: "disclosure", summary: at(text, "Second"), style: "default", children: [] },
    { kind: "image", image: { state: "ready", photo, alt: at(text, "img") } },
  ]
  const row = input(text, blocks, { actions })

  it("rebuilds only the toggled disclosure when openDisclosures changes on the same row", () => {
    const prev = updateBlockTree(undefined, row, { openDisclosures: new Map() })
    expect(prev?.claimedActionIds).toEqual([])
    const next = updateBlockTree(prev, row, { openDisclosures: new Map([["disclosure@1", true]]) })
    expect(next).not.toBe(prev)
    expect(changedRichBlockKeys(prev, next)).toEqual(["disclosure@1"])
    const before = prev?.blocks[1]
    const after = next?.blocks[1]
    expect(before?.kind === "disclosure" && before.open).toBe(false)
    expect(after?.kind === "disclosure" && after.open).toBe(true)
    // The card inside did not change, so it keeps its identity too.
    expect(after?.kind === "disclosure" && before?.kind === "disclosure" && after.children[0]).toBe(
      before?.kind === "disclosure" ? before.children[0] : undefined,
    )
    expect(next?.claimedActionIds).toEqual(["approve"])
    // Closing it again rebuilds the same block only.
    const closed = updateBlockTree(next, row, { openDisclosures: new Map([["disclosure@1", false]]) })
    expect(changedRichBlockKeys(next, closed)).toEqual(["disclosure@1"])
    expect(closed?.claimedActionIds).toEqual([])
  })

  it("returns the previous tree for fresh but equal options", () => {
    const prev = updateBlockTree(undefined, row, { openDisclosures: new Map([["disclosure@2", true]]), text: { phoneNumbers: false } })
    const same = updateBlockTree(prev, row, { openDisclosures: new Map([["disclosure@2", true]]), text: { phoneNumbers: false } })
    expect(same).toBe(prev)
    // Different options rebuild; output that comes out equal keeps its identity.
    expect(updateBlockTree(prev, row, { openDisclosures: new Map([["disclosure@2", true]]) })).toBe(prev)
    const closed = updateBlockTree(prev, row, { text: { phoneNumbers: false } })
    expect(changedRichBlockKeys(prev, closed)).toEqual(["disclosure@2"])
  })

  it("rebuilds only the image when the available width changes", () => {
    const prev = updateBlockTree(undefined, row, { availableWidth: 420 })
    const next = updateBlockTree(prev, row, { availableWidth: 200 })
    expect(changedRichBlockKeys(prev, next)).toEqual(["image@3"])
  })
})

describe("find highlights in blocks", () => {
  const text = "Intro words\nHeading here\nconst x = 1\nE=mc^2"
  const blocks: ContentBlock[] = [
    { kind: "paragraph", text: at(text, "Intro words") },
    { kind: "heading", text: at(text, "Heading here"), level: 2 },
    { kind: "code", text: at(text, "const x = 1") },
    { kind: "math", text: at(text, "E=mc^2") },
  ]
  const findText = (rich: { document: { blocks: readonly unknown[] } }): string[] => {
    const out: string[] = []
    const visit = (value: unknown) => {
      if (Array.isArray(value)) value.forEach(visit)
      else if (value && typeof value === "object") {
        const node = value as { kind?: string; marks?: readonly string[]; text?: string; children?: unknown }
        if (node.kind === "text" && node.marks?.includes("find")) out.push(node.text ?? "")
        if (node.children) visit(node.children)
      }
    }
    visit(rich.document.blocks)
    return out
  }

  it("passes absolute ranges to every block whose text comes from the message, across block edges", () => {
    const start = text.indexOf("words")
    const built = buildBlockTree(input(text, blocks), {
      highlightRanges: [
        [start, text.indexOf("here")], // "words\nHeading " across two blocks
        [text.indexOf("x = 1"), text.indexOf("x = 1") + 1],
        [text.indexOf("mc"), text.indexOf("mc") + 2],
      ],
    })
    if (!built) throw new Error("flat")
    expect(findText(only(built, "paragraph").text)).toEqual(["words"])
    expect(findText(only(built, "heading").text)).toEqual(["Heading "])
    expect(only(built, "code").find).toEqual([{ start: 6, end: 7 }])
    // Math stays inert.
    expect(only(built, "math")).not.toHaveProperty("find")
  })

  it("ignores malformed ranges and rebuilds only the touched block when ranges change", () => {
    const plain = buildBlockTree(input(text, blocks))
    expect(buildBlockTree(input(text, blocks), { highlightRanges: [[-1, 2], [3, 999]] as never })).toEqual(plain)
    const row = input(text, blocks)
    const prev = updateBlockTree(undefined, row, { highlightRanges: [[0, 5]] })
    expect(updateBlockTree(prev, row, { highlightRanges: [[0, 5]] })).toBe(prev)
    const next = updateBlockTree(prev, row, { highlightRanges: [[text.indexOf("Heading"), text.indexOf("Heading") + 7]] })
    expect(changedRichBlockKeys(prev, next)).toEqual(["paragraph@0", "heading@1"])
  })
})
