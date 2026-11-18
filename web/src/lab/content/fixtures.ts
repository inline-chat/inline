/**
 * Lab fixtures: messages covering every media kind, block kind and status,
 * attachment, button, service row and header. Plain data built through a
 * media factory (the lab model), which draws the pictures and makes their
 * stripped previews, so nothing is fetched.
 */

import type {
  ContentBlock,
  Entity,
  EntityType,
  MessageRow,
  PhotoInfo,
  TextRange,
  UserRow,
  VideoInfo,
  VoiceInfo,
} from "@inline/core-protocol"
import type { ChatID, FileID, InlineID, MessageID, PhotoID, UserID } from "@inline/ids"
import type { Picture } from "./pictures"

export const CHAT_ID = "88" as ChatID
export const VIEWER_ID = "1" as UserID

const user = (id: string, fields: Omit<UserRow, "kind" | "id">): UserRow => ({ kind: "user", id: id as UserID, ...fields })

export const USERS: readonly UserRow[] = [
  user("1", { firstName: "Mo", lastName: "Rajabi", username: "mo" }),
  user("2", { firstName: "Ada", lastName: "Lovelace", username: "ada" }),
  user("3", { firstName: "Grace", lastName: "Hopper", username: "grace" }),
  user("4", { firstName: "مریم", lastName: "میرزاخانی", username: "maryam" }),
  user("5", { firstName: "Claude", username: "claude", bot: true }),
  user("6", { firstName: "Linus", username: "linus" }),
]

export const userById = new Map(USERS.map((row) => [row.id, row]))

/** How a lab source behaves. */
export type Behavior = "fast" | "slow" | "fail" | "never" | "missing"

export type MediaFactory = {
  photo(id: string, picture: Picture, behavior: Behavior, options?: { format?: "png"; noStripped?: boolean }): PhotoInfo
  video(id: string, picture: Picture, behavior: Behavior, info: { duration: number; animated?: boolean }): VideoInfo
  voice(id: string, seconds: number, behavior: Behavior): VoiceInfo
}

// ---------------------------------------------------------------------------
// Builders

let nextId = 1000
let date = 1_763_300_000

const message = (from: string, text: string, extra: Partial<MessageRow> = {}): MessageRow => {
  const messageId = String(nextId++) as MessageID
  date += 60
  return {
    kind: "message",
    id: `${CHAT_ID}:${messageId}`,
    chatId: CHAT_ID,
    messageId,
    fromId: from as UserID,
    out: from === VIEWER_ID,
    date,
    text,
    state: "sent",
    ...extra,
  }
}

/** Builds a message text piece by piece and returns the range of each piece. */
const textBuilder = () => {
  let text = ""
  const entities: Entity[] = []
  return {
    add(piece: string, separator = "\n"): TextRange {
      if (text.length > 0) text += separator
      const offset = text.length
      text += piece
      return { offset, length: piece.length }
    },
    entity(range: TextRange, needle: string, type: EntityType, extra: Partial<Entity> = {}) {
      const at = text.indexOf(needle, range.offset)
      if (at < 0 || at + needle.length > range.offset + range.length) throw new Error(`fixture: "${needle}" not in range`)
      entities.push({ type, offset: at, length: needle.length, ...extra })
    },
    get text() {
      return text
    },
    get entities() {
      return entities
    },
  }
}

const blockMessage = (from: string, build: (t: ReturnType<typeof textBuilder>) => ContentBlock[], extra: Partial<MessageRow> = {}) => {
  const t = textBuilder()
  const blocks = build(t)
  return message(from, t.text, { blocks, ...(t.entities.length > 0 ? { entities: t.entities } : {}), ...extra })
}

// ---------------------------------------------------------------------------
// Media

export type Fixture = { readonly title: string; readonly row: MessageRow }

export const mediaFixtures = (media: MediaFactory): Fixture[] => [
  {
    title: "Photo with caption, loads fast",
    row: message("2", "Golden hour from the roof 🌇", {
      media: { kind: "photo", photo: media.photo("p1", { width: 1600, height: 1067, hue: 28, label: "Landscape" }, "fast") },
    }),
  },
  {
    title: "Portrait photo, slow load (blurred preview first)",
    row: message("3", "", {
      media: { kind: "photo", photo: media.photo("p2", { width: 900, height: 1400, hue: 200, label: "Portrait" }, "slow") },
    }),
  },
  {
    title: "Photo whose first load fails (retry inside the box)",
    row: message("2", "This one fails once; press retry.", {
      media: { kind: "photo", photo: media.photo("p3", { width: 1200, height: 900, hue: 120, label: "Retry me" }, "fail") },
    }),
  },
  {
    title: "Photo that never arrives (preview stays)",
    row: message("6", "", {
      media: { kind: "photo", photo: media.photo("p4", { width: 1000, height: 1000, hue: 300, label: "Never" }, "never") },
    }),
  },
  {
    title: "Own photo, slow",
    row: message(VIEWER_ID, "Sent from my desk", {
      media: { kind: "photo", photo: media.photo("p5", { width: 1280, height: 720, hue: 250, label: "Mine" }, "slow") },
    }),
  },
  {
    title: "PNG without caption (no bubble background)",
    row: message("3", "", {
      media: {
        kind: "photo",
        photo: media.photo("p6", { width: 600, height: 400, hue: 160, label: "PNG", transparent: true }, "fast", { format: "png" }),
      },
    }),
  },
  {
    title: "Sticker",
    row: message("4", "", {
      media: {
        kind: "photo",
        sticker: true,
        photo: media.photo("s1", { width: 512, height: 512, hue: 48, label: "", transparent: true }, "fast", { format: "png" }),
      },
    }),
  },
  {
    title: "Panorama and a tiny image (size limits)",
    row: message("2", "", {
      media: { kind: "photo", photo: media.photo("p7", { width: 4000, height: 500, hue: 190, label: "Panorama" }, "fast") },
    }),
  },
  {
    title: "Tiny image (40 px minimum)",
    row: message("6", "", {
      media: { kind: "photo", photo: media.photo("p8", { width: 24, height: 24, hue: 10, label: "" }, "fast") },
    }),
  },
  {
    title: "Video with duration (opens the viewer)",
    row: message("3", "Demo of the new sidebar", {
      media: { kind: "video", video: media.video("v1", { width: 1920, height: 1080, hue: 220, label: "Video" }, "slow", { duration: 75 }) },
    }),
  },
  {
    title: "GIF (muted, looping; still under reduced motion)",
    row: message("2", "", {
      media: {
        kind: "video",
        video: media.video("g1", { width: 480, height: 360, hue: 330, label: "GIF" }, "fast", { duration: 2, animated: true }),
      },
    }),
  },
  {
    title: "Document",
    row: message("6", "", {
      media: {
        kind: "document",
        document: { id: "d1" as FileID, fileName: "Q3 planning.pdf", mimeType: "application/pdf", size: 2_480_000 },
      },
    }),
  },
  {
    title: "Document with a long name and a thumbnail",
    row: message(VIEWER_ID, "", {
      media: {
        kind: "document",
        document: {
          id: "d2" as FileID,
          fileName: "inline-web-architecture-review-final-final-v12.key",
          mimeType: "application/x-iwork-keynote-sffkey",
          size: 18_200_000,
          thumbnail: media.photo("d2t", { width: 400, height: 300, hue: 80, label: "Slides" }, "fast"),
        },
      },
    }),
  },
  {
    title: "Voice note",
    row: message("4", "", { media: { kind: "voice", voice: media.voice("a1", 9, "fast") } }),
  },
  {
    title: "Own voice note",
    row: message(VIEWER_ID, "", { media: { kind: "voice", voice: media.voice("a2", 4, "fast") } }),
  },
]

// ---------------------------------------------------------------------------
// Blocks

const imageInfo = (photo: PhotoInfo) => ({ state: "ready" as const, photo })

export const blockFixtures = (media: MediaFactory): Fixture[] => [
  {
    title: "Text blocks: headings, paragraph with entities, lists, quote, separator, footer",
    row: blockMessage("5", (t) => {
      const h1 = t.add("Release notes")
      const h3 = t.add("What changed")
      const p = t.add("The sidebar now loads from the boot snapshot. See the design doc for details.")
      t.entity(p, "boot snapshot", "bold")
      t.entity(p, "design doc", "textUrl", { url: "https://inline.chat/docs" })
      const b1 = t.add("Faster first paint")
      const b2 = t.add("Fewer layout shifts")
      const n1 = t.add("Open the app")
      const n2 = t.add("Switch chats")
      const k1 = t.add("Ship it")
      const k2 = t.add("Write the post")
      const q = t.add("Instant from local data.")
      const f = t.add("Generated by Claude Code")
      return [
        { kind: "heading", level: 1, text: h1 },
        { kind: "heading", level: 3, text: h3 },
        { kind: "paragraph", text: p },
        { kind: "list", style: "unordered", items: [{ children: [{ kind: "paragraph", text: b1 }] }, { children: [{ kind: "paragraph", text: b2 }] }] },
        {
          kind: "list",
          style: "ordered",
          start: 3,
          items: [{ children: [{ kind: "paragraph", text: n1 }] }, { children: [{ kind: "paragraph", text: n2 }] }],
        },
        {
          kind: "list",
          items: [
            { checked: true, children: [{ kind: "paragraph", text: k1 }] },
            { checked: false, children: [{ kind: "paragraph", text: k2 }] },
          ],
        },
        { kind: "quote", children: [{ kind: "paragraph", text: q }] },
        { kind: "separator" },
        { kind: "footer", text: f },
      ]
    }),
  },
  {
    title: "Code (copy, scrolls inside), math, right-to-left paragraph",
    row: blockMessage("5", (t) => {
      const code = t.add(
        "const snapshot = await store.exportSnapshot(subscriptions, { expand: true }) // a long line that must scroll inside the block only",
      )
      const math = t.add("e^{i\\pi} + 1 = 0")
      const fa = t.add("این پاراگراف راست‌به‌چپ است و باید درست تراز شود.")
      return [
        { kind: "code", language: "typescript", text: code },
        { kind: "math", text: math },
        { kind: "paragraph", text: fa },
      ]
    }),
  },
  {
    title: "Table (scrolls inside), diff, fields",
    row: blockMessage("5", (t) => {
      const cells = ["Budget", "Measured", "Status", "Warm start", "150 ms", "142 ms", "Chat switch", "1 frame", "1 frame", "Send", "1 frame", "2 frames"].map(
        (cell) => t.add(cell, " "),
      )
      const path = t.add("web/src/features/content/reveal.ts")
      const diff = t.add("@@ -1,4 +1,5 @@\n import { signal } from \"@inline/reactive\"\n-const old = 1\n+const next = 2\n+const added = 3\n export {}")
      const l1 = t.add("Command")
      const v1 = t.add("bun run test")
      const l2 = t.add("Owner")
      const v2 = t.add("Ada")
      return [
        {
          kind: "table",
          rows: [cells.slice(0, 3), cells.slice(3, 6), cells.slice(6, 9), cells.slice(9, 12)],
          alignments: [undefined, "right", "center"],
        },
        { kind: "diff", path, text: diff, change: "modified", additions: 2, deletions: 1, language: "typescript" },
        {
          kind: "fields",
          fields: [
            { label: l1, value: v1, monospace: true },
            { label: l2, value: v2, monospace: false },
          ],
        },
      ]
    }),
  },
  {
    title: "Steps card, callouts, meters",
    row: blockMessage("5", (t) => {
      const s = ["Install", "Build", "Test", "Deploy", "Announce", "Roll back"].map((step) => t.add(step))
      const detail = t.add("2 tests failed")
      const titles = ["Note", "Done", "Careful", "Broken"].map((title) => t.add(title))
      const bodies = ["Info callout body.", "Success callout body.", "Warning callout body.", "Error callout body."].map((body) => t.add(body))
      const m = ["Disk", "Quota", "Memory"].map((label) => t.add(label))
      const meta = t.add("72 of 100 GB")
      return [
        {
          kind: "steps",
          steps: [
            { text: s[0], status: "done" },
            { text: s[1], status: "done" },
            { text: s[2], status: "failed", detail },
            { text: s[3], status: "running" },
            { text: s[4], status: "waiting" },
            { text: s[5], status: "cancelled" },
          ],
        },
        ...(["info", "success", "warning", "error"] as const).map(
          (tone, index): ContentBlock => ({
            kind: "callout",
            tone,
            title: titles[index],
            children: [{ kind: "paragraph", text: bodies[index] }],
          }),
        ),
        { kind: "meter", label: m[0], value: 72, max: 100, meta },
        { kind: "meter", label: m[1], value: 91, max: 100, tone: "warning" },
        { kind: "meter", label: m[2], value: 120, max: 100, tone: "critical" },
      ]
    }),
  },
  {
    title: "Disclosures: closed, open, running with timer and shimmer, waiting, failed, cancelled",
    row: blockMessage("5", (t) => {
      const summaries = ["Reasoning", "Read 3 files", "Running tests", "Waiting for approval", "Search failed", "Cancelled edit"].map((s) =>
        t.add(s),
      )
      const inner = ["Thought about the anchor model.", "reveal.ts, sources.ts, env.ts", "vitest run", "", "", ""].map((s) =>
        s ? t.add(s) : undefined,
      )
      const meta = t.add("3 files")
      const now = Math.floor(Date.now() / 1000)
      return [
        { kind: "disclosure", summary: summaries[0], style: "default", children: [{ kind: "paragraph", text: inner[0] }] },
        { kind: "disclosure", summary: summaries[1], style: "default", initiallyOpen: true, meta, children: [{ kind: "paragraph", text: inner[1] }] },
        {
          kind: "disclosure",
          summary: summaries[2],
          style: "progress",
          status: "running",
          activity: "command",
          startedAt: now - 42,
          children: [{ kind: "code", text: inner[2] }],
        },
        { kind: "disclosure", summary: summaries[3], style: "progress", status: "waiting", children: [] },
        { kind: "disclosure", summary: summaries[4], style: "progress", status: "failed", activity: "search", children: [] },
        { kind: "disclosure", summary: summaries[5], style: "progress", status: "cancelled", activity: "edit", children: [] },
      ]
    }),
  },
  {
    title: "Image blocks: ready (slow), pending with preview, unavailable; album",
    row: blockMessage("5", (t) => {
      const alt = t.add("A chart of start-up times")
      return [
        { kind: "image", image: { ...imageInfo(media.photo("bi1", { width: 800, height: 450, hue: 210, label: "Chart" }, "slow")), alt } },
        {
          kind: "image",
          image: {
            state: "pending",
            width: 600,
            height: 300,
            stripped: media.photo("bi2", { width: 600, height: 300, hue: 15, label: "Pending" }, "never").stripped,
          },
        },
        { kind: "image", image: { state: "unavailable", width: 400, height: 200 } },
        {
          kind: "album",
          images: [0, 1, 2, 3, 4].map((index) =>
            imageInfo(
              media.photo(
                `al${index}`,
                { width: [1200, 800, 600, 1600, 500][index] ?? 800, height: [800, 1200, 600, 400, 900][index] ?? 600, hue: index * 60, label: `#${index + 1}` },
                index === 3 ? "fail" : index === 1 ? "slow" : "fast",
              ),
            ),
          ),
        },
      ]
    }),
  },
  {
    title: "Form with every field kind (one submit; the secret is never shown back)",
    row: blockMessage("5", (t) => {
      const title = t.add("Deploy settings")
      const labels = ["Environment", "Regions", "Release name", "Notes", "API token", "Notify the channel", "Replicas", "Rollout"].map((l) =>
        t.add(l),
      )
      const opts = ["Staging", "Production", "Preview", "eu-west", "us-east", "ap-south"].map((o) => t.add(o))
      const header = t.add("Advanced")
      const description = t.add("Used once, then forgotten.")
      const rollouts = Array.from({ length: 8 }, (_, index) => t.add(`${(index + 1) * 10}%`))
      return [
        {
          kind: "form",
          formId: "deploy",
          title,
          closed: false,
          submitLabel: "Deploy",
          fields: [
            {
              fieldId: "env",
              label: labels[0],
              required: true,
              input: {
                kind: "select",
                multiple: false,
                allowOther: false,
                defaultOptionIds: ["staging"],
                options: [
                  { optionId: "staging", label: opts[0], recommended: true },
                  { optionId: "production", label: opts[1], recommended: false },
                  { optionId: "preview", label: opts[2], recommended: false },
                ],
              },
            },
            {
              fieldId: "regions",
              label: labels[1],
              required: false,
              input: {
                kind: "select",
                multiple: true,
                allowOther: true,
                defaultOptionIds: [],
                options: [
                  { optionId: "eu", label: opts[3], recommended: false },
                  { optionId: "us", label: opts[4], recommended: false },
                  { optionId: "ap", label: opts[5], recommended: false },
                ],
              },
            },
            { fieldId: "name", label: labels[2], required: true, input: { kind: "text", style: "singleLine", placeholder: "v1.2.3", maxLength: 40 } },
            { fieldId: "notes", label: labels[3], required: false, input: { kind: "text", style: "multiline" } },
            { fieldId: "token", label: labels[4], header, description, required: false, input: { kind: "text", style: "secret" } },
            { fieldId: "notify", label: labels[5], required: false, input: { kind: "toggle", defaultValue: true } },
            { fieldId: "replicas", label: labels[6], required: false, input: { kind: "number", defaultValue: 2, min: 1, max: 10, step: 1, integer: true } },
            {
              fieldId: "rollout",
              label: labels[7],
              required: false,
              input: {
                kind: "select",
                multiple: false,
                allowOther: false,
                defaultOptionIds: [],
                options: rollouts.map((label, index) => ({ optionId: `r${index}`, label, recommended: index === 4 })),
              },
            },
          ],
        },
      ]
    }),
  },
  {
    title: "Closed form, and a form the viewer lacks the grant for",
    row: blockMessage("5", (t) => {
      const a = t.add("Pick a time")
      const b = t.add("Approve budget")
      const o = t.add("Tomorrow 10:00")
      const l = t.add("Amount")
      return [
        {
          kind: "form",
          formId: "closed",
          title: a,
          closed: true,
          fields: [
            {
              fieldId: "time",
              label: a,
              required: true,
              input: { kind: "select", multiple: false, allowOther: false, defaultOptionIds: ["t1"], options: [{ optionId: "t1", label: o, recommended: false }] },
            },
          ],
        },
        {
          kind: "form",
          formId: "granted",
          title: b,
          closed: false,
          requiredGrant: "approve",
          fields: [{ fieldId: "amount", label: l, required: true, input: { kind: "number", integer: true, step: 1 } }],
        },
      ]
    }),
  },
  {
    title: "Widget placeholder (no frame), and an unknown block kind (falls back to its text)",
    row: blockMessage("5", (t) => {
      const title = t.add("Burn-down chart")
      const unknown = t.add("Text an older build shows for a block it does not know.")
      void unknown
      return [{ kind: "widget", widgetId: "w1", title, htmlLength: 2048, height: 180, images: [] }, { kind: "unknown" }]
    }),
  },
  {
    title: "Agent cards: plan proposal (pending) and approval (pending)",
    row: blockMessage(
      "5",
      (t) => {
        const plan = t.add("Plan: content views")
        const steps = Array.from({ length: 14 }, (_, index) => t.add(`Step ${index + 1}: do the next thing well`))
        const approve = t.add("Run the test suite")
        const cmd = t.add("bunx vitest run src/features/content")
        const cwd = t.add("/Users/mo/dev/inline-chat/inline/web")
        const reason = t.add("Checks the controllers before the lab.")
        return [
          {
            kind: "planProposal",
            title: plan,
            state: "pending",
            actionIds: ["plan-accept", "plan-revise"],
            children: [{ kind: "list", style: "ordered", items: steps.map((text) => ({ children: [{ kind: "paragraph", text }] })) }],
          },
          { kind: "approval", subject: "command", title: approve, command: cmd, cwd, reason, state: "pending", actionIds: ["run-yes", "run-no"], children: [] },
        ]
      },
      {
        actions: [
          [
            { actionId: "plan-accept", text: "Approve plan", style: "primary", action: { kind: "callback" } },
            { actionId: "plan-revise", text: "Keep planning", style: "default", action: { kind: "callback" } },
          ],
          [
            { actionId: "run-yes", text: "Run", style: "primary", action: { kind: "callback" }, requiredGrant: "approve" },
            { actionId: "run-no", text: "Decline", style: "destructive", action: { kind: "callback" } },
          ],
        ],
      },
    ),
  },
  {
    title: "Agent cards: decided plan, declined approval, review with findings",
    row: blockMessage("5", (t) => {
      const plan = t.add("Plan: timeline")
      const step = t.add("Done already")
      const approve = t.add("Delete the cache")
      const cmd = t.add("rm -rf ~/Library/Caches/inline")
      const review = t.add("Review of the content views")
      const summary = t.add("Two things to fix before landing.")
      const f1 = t.add("Retry button nested in a button")
      const f1b = t.add("Interactive content inside a button is invalid HTML.")
      const f1p = t.add("web/src/features/content/MediaViews.tsx")
      const f2 = t.add("Missing reduced-motion check")
      return [
        { kind: "planProposal", title: plan, state: "accepted", actionIds: [], children: [{ kind: "paragraph", text: step }] },
        { kind: "approval", subject: "command", title: approve, command: cmd, state: "declined", actionIds: [], children: [] },
        {
          kind: "review",
          title: review,
          verdict: "needsAttention",
          summary,
          findings: [
            { title: f1, body: f1b, priority: "p1", path: f1p, startLine: 120, endLine: 134, confidence: "confirmed", outcome: "fixed" },
            { title: f2, priority: "p2", category: "Accessibility", confidence: "plausible", actionId: "fix-motion" },
          ],
        },
      ]
    }, {
      actions: [[{ actionId: "fix-motion", text: "Fix it", style: "default", action: { kind: "compose", text: "Please add the reduced-motion check." } }]],
    }),
  },
  {
    title: "Agent cards: task suggestions (pending, accepted with thread, expired), next step, prompt suggestions",
    row: blockMessage(
      "5",
      (t) => {
        const s1 = t.add("Write the media scheduler")
        const b1 = t.add("Owns transfers and priorities, separate from sync.")
        const s2 = t.add("Port the lab to Solid")
        const s3 = t.add("Old suggestion")
        const recap = t.add("The content views are in.")
        const question = t.add("Wire them into the chat pane now?")
        const p = ["Wire it up", "Show me the lab", "Write the README"].map((label) => t.add(label))
        return [
          { kind: "taskSuggestion", title: s1, brief: b1, state: "pending", actionIds: ["task-yes", "task-no"] },
          { kind: "taskSuggestion", title: s2, state: "accepted", startedPeer: { kind: "chat", chatId: "99" as ChatID }, actionIds: [] },
          { kind: "taskSuggestion", title: s3, state: "expired", actionIds: [] },
          { kind: "nextStep", recap, question, actionIds: ["next-yes", "next-later"], blocking: true },
          { kind: "promptSuggestions", prompts: [{ label: p[0], text: "Wire MessageContent into the chat pane." }, { label: p[1] }, { label: p[2] }] },
        ]
      },
      {
        actions: [
          [
            { actionId: "task-yes", text: "Start", style: "primary", action: { kind: "callback" } },
            { actionId: "task-no", text: "Dismiss", style: "default", action: { kind: "callback" } },
          ],
          [
            { actionId: "next-yes", text: "Yes, wire it", style: "primary", action: { kind: "callback" } },
            { actionId: "next-later", text: "Later", style: "default", action: { kind: "compose", text: "Later, after the review." } },
          ],
        ],
      },
    ),
  },
]

// ---------------------------------------------------------------------------
// Streaming

/** The text a streaming agent message grows into, as block pieces. */
export const STREAM_PIECES = [
  "Looking at the timeline anchor model first.",
  "The capture step records every visible row with its offset.",
  "Restoring uses the first row that still exists, so deletions do not lose the place.",
  "Corrections under half a pixel are skipped on purpose.",
  "Media boxes are reserved from metadata, so an image arriving never moves the reader.",
]

export const streamRow = (id: string, words: number, startedAt: number): MessageRow => {
  const t = textBuilder()
  const summary = t.add("Reading the anchor model")
  const blocks: ContentBlock[] = [
    { kind: "heading", level: 3, text: t.add("Working notes") },
    { kind: "disclosure", summary, style: "progress", status: "running", startedAt, children: [] },
  ]
  let remaining = words
  for (const piece of STREAM_PIECES) {
    if (remaining <= 0) break
    const taken = piece.split(" ").slice(0, remaining)
    remaining -= taken.length
    blocks.push({ kind: "paragraph", text: t.add(taken.join(" ")) })
  }
  return {
    kind: "message",
    id,
    chatId: CHAT_ID,
    messageId: "9000" as MessageID,
    fromId: "5" as UserID,
    out: false,
    date: date + 600,
    text: t.text,
    state: "sent",
    blocks,
  }
}

export const STREAM_TOTAL_WORDS = STREAM_PIECES.reduce((sum, piece) => sum + piece.split(" ").length, 0)

// ---------------------------------------------------------------------------
// Attachments and buttons

export const attachmentFixtures = (media: MediaFactory): Fixture[] => [
  {
    title: "Compact link preview with thumbnail, and one with an emoji",
    row: message("2", "https://inline.chat/blog/web and https://example.com/notes", {
      attachments: [
        {
          kind: "urlPreview",
          id: "u1" as InlineID,
          url: "https://inline.chat/blog/web",
          siteName: "Inline",
          title: "Inline for the web",
          description: "The web client, built to match the Mac app: instant from local data, complete from the keyboard.",
          photo: media.photo("u1p", { width: 1200, height: 630, hue: 195, label: "OG" }, "fast"),
        },
        { kind: "urlPreview", id: "u2" as InlineID, url: "https://example.com/notes", title: "Meeting notes", iconEmoji: "📝" },
      ],
    }),
  },
  {
    title: "Large video preview (YouTube, slow image) and an X post",
    row: message("3", "Worth a watch", {
      attachments: [
        {
          kind: "urlPreview",
          id: "u3" as InlineID,
          url: "https://www.youtube.com/watch?v=lab",
          provider: "youtube",
          author: "Inline",
          title: "Designing a desktop-grade chat client",
          description: "A walk through the timeline, the composer and the media pipeline.",
          duration: 1265,
          mediaType: "video",
          photo: media.photo("u3p", { width: 1280, height: 720, hue: 0, label: "Video" }, "slow"),
        },
        {
          kind: "urlPreview",
          id: "u4" as InlineID,
          url: "https://x.com/inline/status/1",
          provider: "x",
          author: "Inline",
          description: "Web app foundation landed today. Rows paint from local data in the first frame.",
        },
      ],
    }),
  },
  {
    title: "Preview whose URL the allowlist refuses (text only, not clickable)",
    row: message("6", "javascript:alert(1)", {
      attachments: [{ kind: "urlPreview", id: "u5" as InlineID, url: "javascript:alert(1)", title: "Not a link" }],
    }),
  },
  {
    title: "External tasks: Linear issue, will do, unassigned",
    row: message(VIEWER_ID, "Tracked", {
      attachments: [
        { kind: "externalTask", id: "t1" as InlineID, taskId: "WEB-12", application: "linear", title: "Media scheduler", assigneeUserId: "2" as UserID, number: "WEB-12", url: "https://linear.app/inline/issue/WEB-12" },
        { kind: "externalTask", id: "t2" as InlineID, taskId: "n1", application: "notion", title: "Write the post", assigneeUserId: "3" as UserID, status: "done" },
        { kind: "externalTask", id: "t3" as InlineID, taskId: "n2", application: "notion", title: "" },
      ],
    }),
  },
  {
    title: "Bot buttons: callback (spinner), copy, open URL, unavailable URL, compose, open chat, gated, confirm",
    row: message("5", "What next?", {
      actions: [
        [
          { actionId: "b1", text: "Run again", style: "primary", action: { kind: "callback" } },
          { actionId: "b2", text: "Copy ID", style: "default", action: { kind: "copyText", text: "run_123" } },
        ],
        [
          { actionId: "b3", text: "Open logs", style: "default", action: { kind: "openUrl", url: "https://example.com/logs" } },
          { actionId: "b4", text: "Open in Codex", style: "default", action: { kind: "openUrl", url: "codex://run/1" } },
        ],
        [
          { actionId: "b5", text: "Reply", style: "default", action: { kind: "compose", text: "Looks good, ship it." } },
          { actionId: "b6", text: "Open thread", style: "default", action: { kind: "openLink", peer: { kind: "chat", chatId: "99" as ChatID } } },
        ],
        [
          { actionId: "b7", text: "Approve", style: "primary", action: { kind: "callback" }, requiredGrant: "approve" },
          { actionId: "b8", text: "Delete run", style: "destructive", action: { kind: "callback" }, confirm: { title: "Delete this run?", confirmText: "Delete" } },
        ],
      ],
    }),
  },
]

// ---------------------------------------------------------------------------
// Headers and service rows

export const headerFixtures = (): Fixture[] => [
  { title: "Forwarded from a chat", row: message("2", "Forwarded note", { forward: { fromPeer: { kind: "chat", chatId: "99" as ChatID }, fromMessageId: "5" as MessageID } }) },
  { title: "Forwarded from a private chat (unknown source)", row: message(VIEWER_ID, "Forwarded by me", { forward: { fromUserId: "77" as UserID } }) },
  { title: "Sent via an agent", row: message("2", "Pushed the fix.", { via: { kind: "app", app: "claude-code", name: "Claude Code" } }) },
  { title: "Sent via a bot", row: message("3", "Nightly report is ready.", { via: { kind: "bot", botUserId: "5" as UserID, name: "Reporter" } }) },
  {
    title: "Reply thread summary (unread, three avatars)",
    row: message("2", "Should we ship Friday?", {
      replies: { kind: "reply", chatId: "101" as ChatID, count: 12, hasUnread: true, recentUserIds: ["3", "4", "6", "1"] as UserID[] },
    }),
  },
  {
    title: "Subthread summary with a title",
    row: message(VIEWER_ID, "Kicking off the web launch", {
      replies: { kind: "subthread", chatId: "102" as ChatID, count: 1, hasUnread: false, recentUserIds: ["2"] as UserID[], title: "Launch checklist" },
    }),
  },
]

export const serviceFixtures = (): Fixture[] => [
  { title: "Thread backlink with a title", row: message("2", "", { service: { kind: "threadBacklink", sourceChatId: "99" as ChatID, sourceTitle: "Design review" } }) },
  { title: "Thread backlink without a title, by me", row: message(VIEWER_ID, "", { service: { kind: "threadBacklink" } }) },
  { title: "Pinned message", row: message("3", "", { service: { kind: "pinnedMessage", messageId: "1000" as MessageID } }) },
  {
    title: "Transcript turn by another speaker",
    row: message("5", "Transcript · Ada: let's start with the timeline.", {
      service: { kind: "gridTranscript", runId: "r1", segmentId: "s1", speakerUserId: "2" as UserID, event: "turn" },
    }),
  },
  (() => {
    const text = "Recording stopped. Summary in Launch notes."
    return {
      title: "Transcript status with a thread link",
      row: message("5", text, {
        service: { kind: "gridTranscript", runId: "r1", segmentId: "s2", event: "stopped" },
        entities: [{ type: "thread", offset: text.indexOf("Launch notes"), length: "Launch notes".length, chatId: "103" as ChatID }],
      }),
    }
  })(),
  { title: "Unknown service event (its text)", row: message("6", "Something happened that this build does not know.", { service: { kind: "unknown" } }) },
]

export const chatTitles = new Map<string, string>([
  ["99", "Design review"],
  ["101", "Ship Friday?"],
])

/** Photo IDs are lab strings; the factory brands them. */
export const photoId = (id: string): PhotoID => id as PhotoID
export const fileId = (id: string): FileID => id as FileID
