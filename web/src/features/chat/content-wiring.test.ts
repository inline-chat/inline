import type { ButtonModel } from "@inline/chat-ui"
import type { ActionAnswer, MessageRow, MessageRowId, PhotoInfo, TxId } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { effect, signal } from "@inline/reactive"
import { mediaModel } from "@inline/chat-ui"
import type { ActionHandle, ActionNotice, ActionOutcome, ActionResult } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { createContentEnv } from "../content/env"
import { constantSource, type MediaSource, type MediaSources } from "../content/sources"
import type { OpenMediaInput } from "../content/env"
import type { AttachmentDrafts, ComposerAttachments } from "../composer/attachments"
import { followUploadActivity, type UploadActivity } from "../composer/attachments"
import { chatDropTarget, SessionAttachments } from "./chat-attachments"
import { ChatContent, type ChatContentOptions, type PaneMediaSources } from "./chat-content"
import { contentHandlers, contentNames } from "./content-handlers"
import type { ContentChunk } from "./content-chunk"
import { MediaViewerHost } from "./media-viewer-host"
import { MediaViewerModel, viewerItems } from "./media-viewer"
import type { ConfirmRequest } from "./message-actions"

/**
 * The content environment's wiring in the chat pane (bot buttons, forms,
 * the media layer and its visibility, opening media), the media viewer and
 * the attachments loaded on the first file. Fakes stand in for the
 * session's actions and the chunks; the models are the real ones.
 */

const rowId = "5:1" as MessageRowId
const tx = "t1" as TxId
const notice: ActionNotice = { kind: "refused", tone: "error", title: "Couldn't run the action", text: "The bot refused." }

const handle = (first: ActionResult, outcome: ActionOutcome): ActionHandle =>
  Object.assign(Promise.resolve(first), { tx, outcome: Promise.resolve(outcome) })

const button = (behavior: ButtonModel["behavior"], confirm?: ButtonModel["confirm"]): ButtonModel => ({
  key: "b",
  actionId: "a1",
  label: "Go",
  style: undefined as never,
  behavior,
  confirm,
  requiredGrant: undefined,
})

const chunk = (sources?: PaneMediaSources) => {
  const value = signal<ContentChunk | undefined>(undefined)
  const module = {
    createContentEnv,
    contentHandlers,
    contentNames,
    createCoreMediaSources: () => sources,
  } as unknown as ContentChunk
  return { value, arrive: () => value.set(module) }
}

const setup = (extra: Partial<ChatContentOptions> = {}, sources?: PaneMediaSources) => {
  const c = chunk(sources)
  const calls: string[] = []
  const toasts: { title: string; description?: string; tone?: string }[] = []
  const asked: ConfirmRequest[] = []
  const content = new ChatContent({
    chunk: c,
    peekRow: () => undefined,
    userId: "1" as UserID,
    currentChatId: () => "5" as ChatID,
    open: (destination) => void calls.push(`open:${JSON.stringify(destination)}`),
    threadsInSidePane: () => false,
    parseAppLink: () => undefined,
    openExternal: (url) => void calls.push(`external:${url}`),
    copyText: (text) => void calls.push(`copy:${text}`),
    compose: (text) => void calls.push(`compose:${text}`),
    toast: (toast) => void toasts.push(toast),
    confirm: (request) => void asked.push(request),
    ...(sources ? { mediaSources: () => sources } : {}),
    ...extra,
  })
  return { content, arrive: c.arrive, calls, toasts, asked }
}

const handlers = (s: ReturnType<typeof setup>) => {
  s.arrive()
  const env = s.content.env.peek()
  if (!env) throw new Error("no env")
  return env.handlers
}

describe("bot buttons", () => {
  it("routes a callback to the session's invokeAction and spins until the final outcome", async () => {
    let settle!: (outcome: ActionOutcome) => void
    const invoked: string[] = []
    const s = setup({
      invokeAction: (row, actionId) => {
        invoked.push(`${row}/${actionId}`)
        return Object.assign(Promise.resolve({ status: "accepted", tx } as ActionResult), {
          tx,
          outcome: new Promise<ActionOutcome>((resolve) => (settle = resolve)),
        })
      },
    })
    const result = handlers(s).onAction?.({ rowId, button: button({ kind: "callback" }) })
    expect(invoked).toEqual([`${rowId}/a1`])
    let done = false
    void Promise.resolve(result).then(() => (done = true))
    await Promise.resolve()
    expect(done).toBe(false)
    settle({ status: "confirmed", tx })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(done).toBe(true)
  })

  it("copies, opens links, composes and refuses unavailable buttons", () => {
    const s = setup()
    const h = handlers(s)
    h.onAction?.({ rowId, button: button({ kind: "copy", text: "abc" }) })
    h.onAction?.({ rowId, button: button({ kind: "compose", text: "/deploy" }) })
    h.onAction?.({ rowId, button: button({ kind: "openLink", peer: { kind: "chat", chatId: "9" as ChatID }, messageId: "3" as MessageID }) })
    h.onAction?.({ rowId, button: button({ kind: "openUrl", link: { kind: "web", href: "https://example.com/" } as never }) })
    h.onAction?.({ rowId, button: button({ kind: "unavailable", reason: "Unknown action" }) })
    expect(s.calls).toEqual([
      "copy:abc",
      "compose:/deploy",
      `open:${JSON.stringify({ kind: "message", chatId: "9", messageId: "3" })}`,
      "external:https://example.com/",
    ])
    expect(s.toasts.map((toast) => toast.title)).toEqual(["Copied", "This action isn’t available"])
  })

  it("asks first for a button with a confirm step, and does nothing when declined", async () => {
    const s = setup()
    const h = handlers(s)
    const confirm = { title: "Open example.com?", text: "It leaves Inline.", confirmLabel: "Open" }
    const declined = h.onAction?.({ rowId, button: button({ kind: "openUrl", link: { kind: "web", href: "https://example.com/" } as never }, confirm) })
    expect(s.asked[0]).toMatchObject({ title: "Open example.com?", description: "It leaves Inline.", confirmLabel: "Open" })
    expect(s.calls).toEqual([])
    s.asked[0]?.cancel?.()
    await declined
    const accepted = h.onAction?.({ rowId, button: button({ kind: "openUrl", link: { kind: "web", href: "https://example.com/" } as never }, confirm) })
    s.asked[1]?.run()
    await accepted
    expect(s.calls).toEqual(["external:https://example.com/"])
  })

  it("names the real destination under the bot's words in a confirm step, and shows what a copy button copied", () => {
    const s = setup()
    const h = handlers(s)
    // The bot's title and text say one thing; the app says where the link goes.
    const confirm = { title: "Open the docs?", text: "Our official documentation.", confirmLabel: "Open" }
    const link = { kind: "web", href: "https://evil.example.net/docs", host: "evil.example.net" } as never
    void h.onAction?.({ rowId, button: button({ kind: "openUrl", link }, confirm) })
    expect(s.asked[0]).toMatchObject({ description: "Our official documentation.", detail: "Opens evil.example.net" })
    void h.onAction?.({ rowId, button: button({ kind: "openUrl", link: { kind: "mail", href: "mailto:a@b.c", address: "a@b.c" } as never }, confirm) })
    expect(s.asked[1]?.detail).toBe("Opens a@b.c")
    void h.onAction?.({ rowId, button: button({ kind: "copy", text: "rm -rf ~" }, { title: "Copy the command?", text: undefined, confirmLabel: "Copy" }) })
    expect(s.asked[2]?.detail).toBe("Copies “rm -rf ~”")
    s.asked[2]?.run()
    expect(s.calls).toEqual(["copy:rm -rf ~"])
    expect(s.toasts.at(-1)).toMatchObject({ title: "Copied", description: "“rm -rf ~”" })
    // Long text: the start, and how long it really was.
    h.onAction?.({ rowId, button: button({ kind: "copy", text: "x".repeat(200) }) })
    expect(s.toasts.at(-1)?.description).toMatch(/^“x{70,80}…?” \(200 characters\)$/)
  })
})

describe("downloads", () => {
  const doc = (fileName: string) => ({ kind: "document", document: { id: "f1", fileName, mimeType: "application/pdf", size: 3 } }) as never

  it("saves a document's file from the core under a safe name, and says so when it cannot", async () => {
    const subscribed: unknown[] = []
    let resource: ReturnType<typeof signal<unknown>> | undefined
    const client = {
      subscribe: (query: unknown) => {
        subscribed.push(query)
        resource = signal<unknown>(undefined)
        return { resource, unsubscribe: () => void subscribed.push("unsubscribe") } as never
      },
    }
    const saved: string[] = []
    const s = setup({
      files: {
        client,
        target: (row) => (row === rowId ? { chatId: "5" as ChatID, messageId: "1" as MessageID } : undefined),
        save: (blob, name) => void saved.push(`${name}:${blob.size}`),
      },
    })
    const h = handlers(s)
    h.onDownload?.({ rowId, media: doc("invoice\u202Efdp.exe/../x") })
    expect(subscribed[0]).toEqual({ kind: "media", media: { kind: "message", chatId: "5", messageId: "1" }, priority: "opened" })
    resource!.set({ kind: "media", state: "downloading" })
    resource!.set({ kind: "media", state: "ready", blob: new Blob(["abc"]) })
    await new Promise((resolve) => setTimeout(resolve, 0))
    // Bidi controls gone, path separators replaced.
    expect(saved).toEqual(["invoicefdp.exe_.._x:3"])
    expect(subscribed).toContain("unsubscribe")

    h.onDownload?.({ rowId, media: doc("a.pdf") })
    resource!.set({ kind: "media", state: "failed" })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(saved).toHaveLength(1)
    expect(s.toasts.at(-1)).toMatchObject({ title: "Couldn't download the file", tone: "error" })

    // A row still sending has no file on the server yet: nothing is asked.
    h.onDownload?.({ rowId: "5:r9" as MessageRowId, media: doc("b.pdf") })
    expect(subscribed.filter((entry) => entry !== "unsubscribe")).toHaveLength(2)
  })
})

describe("forms", () => {
  const answer: ActionAnswer = { kind: "toast", text: "Deploying" } as ActionAnswer

  it("resolves when confirmed and shows the bot's answer", async () => {
    const submitted: string[] = []
    const s = setup({
      submitForm: (row, formId) => {
        submitted.push(`${row}/${formId}`)
        return handle({ status: "accepted", tx }, { status: "confirmed", tx, answer })
      },
    })
    await expect(handlers(s).onSubmitForm?.({ rowId, formId: "f", values: [] })).resolves.toBeUndefined()
    expect(submitted).toEqual([`${rowId}/f`])
    expect(s.toasts.map((toast) => toast.title)).toEqual(["Deploying"])
  })

  it("rejects on a refusal, first or final, so the form can be sent again, and says why", async () => {
    const refused = setup({ submitForm: () => handle({ status: "rejected", reason: "offline", retryable: true, notice } as ActionResult, { status: "rejected", notice } as ActionOutcome) })
    await expect(handlers(refused).onSubmitForm?.({ rowId, formId: "f", values: [] })).rejects.toThrow()
    expect(refused.toasts).toEqual([expect.objectContaining({ title: notice.title, tone: "error" })])

    const later = setup({ submitForm: () => handle({ status: "accepted", tx }, { status: "rejected", reason: "server", retryable: false, notice } as ActionOutcome) })
    await expect(handlers(later).onSubmitForm?.({ rowId, formId: "f", values: [] })).rejects.toThrow()
  })

  it("keeps an uncertain submit as sent (a retry could send it twice) and says it is not confirmed", async () => {
    const uncertain: ActionNotice = { kind: "uncertain", tone: "warning", title: "Not confirmed yet", text: "…" }
    const s = setup({ submitForm: () => handle({ status: "accepted", tx }, { status: "uncertain", notice: uncertain } as ActionOutcome) })
    await expect(handlers(s).onSubmitForm?.({ rowId, formId: "f", values: [] })).resolves.toBeUndefined()
    expect(s.toasts).toEqual([expect.objectContaining({ title: "Not confirmed yet", tone: "warning" })])
  })
})

const photo = (id: string, width = 800, height = 600): PhotoInfo =>
  ({ id, sizes: [{ type: "c", width: 320, height: 240 }, { type: "d", width, height }] }) as unknown as PhotoInfo

const photoRow = (n: number): MessageRow =>
  ({
    kind: "message",
    id: `5:${n}`,
    chatId: "5",
    messageId: String(n),
    fromId: "2",
    out: false,
    date: n,
    text: "",
    state: "sent",
    media: { kind: "photo", photo: photo(`p${n}`) },
  }) as unknown as MessageRow

const fakeSources = () => {
  const held: string[] = []
  const opened: string[] = []
  const attached: Element[] = []
  const sources: PaneMediaSources & { open(source: MediaSource): void; hold(source: MediaSource): () => void } = {
    photo: (info, box) => Object.assign(constantSource({ status: "ready", url: `blob:${info.id}@${box.width}` }), { id: info.id }),
    video: () => constantSource({ status: "failed" }),
    voice: () => constantSource({ status: "failed" }),
    open: (source) => void opened.push((source as unknown as { id: string }).id),
    hold: (source) => {
      const id = (source as unknown as { id: string }).id
      held.push(id)
      return () => void held.splice(held.indexOf(id), 1)
    },
    createVisibility: () => ({
      attach: (element: Element) => {
        attached.push(element)
        return () => void attached.splice(attached.indexOf(element), 1)
      },
      dispose: () => {},
    }),
  }
  return { sources, held, opened, attached }
}

describe("media in the content environment", () => {
  it("uses the session's media layer and attaches its visibility to the timeline's scroller, whichever comes first", () => {
    const media = fakeSources()
    const s = setup({}, media.sources)
    const scroller = {} as Element
    const detach = s.content.scroller(scroller)
    expect(media.attached).toEqual([])
    s.arrive()
    expect(s.content.env.peek()?.sources).toBe(media.sources)
    expect(media.attached).toEqual([scroller])
    detach()
    expect(media.attached).toEqual([])
    s.content.scroller(scroller)
    expect(media.attached).toEqual([scroller])
    s.content.dispose()
  })

  it("opens a photo in the viewer over the same media layer", () => {
    const media = fakeSources()
    const opened: { input: OpenMediaInput; sources: MediaSources }[] = []
    const s = setup({ openMedia: (input, sources) => void opened.push({ input, sources }) }, media.sources)
    const input: OpenMediaInput = { rowId, key: "photo:p1", kind: "photo", photo: photo("p1"), video: undefined }
    handlers(s).onOpenMedia?.(input)
    expect(opened).toEqual([{ input, sources: media.sources }])
  })
})

describe("media viewer", () => {
  it("lists the window's photos, starts at the one opened, and steps with the arrow keys (mirrored right to left)", () => {
    const rows = [photoRow(1), { ...photoRow(2), media: undefined } as MessageRow, photoRow(3), photoRow(4)]
    const { items, index } = viewerItems(rows, { rowId: "5:3" as MessageRowId, key: "photo:p3", kind: "photo", photo: photo("p3"), video: undefined })
    expect(items.map((item) => item.rowId)).toEqual(["5:1", "5:3", "5:4"])
    expect(index).toBe(1)

    const media = fakeSources()
    const isOpen = signal(false)
    const closed: string[] = []
    const model = new MediaViewerModel({
      items,
      index,
      sources: media.sources,
      onClosed: () => void closed.push("closed"),
      dialog: (onOpenChange) => ({
        isOpen,
        open: () => {
          isOpen.set(true)
          onOpenChange(true)
        },
        close: () => {
          if (!isOpen.peek()) return
          isOpen.set(false)
          onOpenChange(false)
        },
      }),
    })
    model.open()
    // The largest stored size, asked with priority and held while shown.
    expect(model.source.peek()?.state.peek()).toEqual({ status: "ready", url: "blob:p3@800" })
    expect(media.opened).toEqual(["p3"])
    expect(media.held).toEqual(["p3"])
    expect(model.position.peek()).toBe("2 of 3")

    expect(model.key("ArrowRight")).toBe(true)
    expect(model.current.peek()?.rowId).toBe("5:4")
    expect(media.held).toEqual(["p4"])
    expect(model.canNext.peek()).toBe(false)
    model.key("ArrowRight")
    expect(model.current.peek()?.rowId).toBe("5:4")
    model.key("ArrowRight", "rtl")
    expect(model.current.peek()?.rowId).toBe("5:3")
    expect(model.key("Enter")).toBe(false)

    model.close()
    expect(closed).toEqual(["closed"])
    model.dispose()
    expect(media.held).toEqual([])
  })

  it("shows media that is not a message's own alone", () => {
    const { items, index } = viewerItems([photoRow(1)], {
      rowId: "5:9" as MessageRowId,
      key: "image@0",
      kind: "image",
      photo: photo("block"),
      video: undefined,
    })
    expect(items).toHaveLength(1)
    expect(items[0]?.photo?.id).toBe("block")
    expect(index).toBe(0)
  })

  it("loads its chunk on the first open, and a new open replaces the viewer", async () => {
    const value = signal<typeof import("./media-viewer-chunk") | undefined>(undefined)
    let loads = 0
    const layers: string[] = []
    const keyboard = {
      pushLayer: (scope: string, options?: { modal?: boolean }) => {
        layers.push(`${scope}:${options?.modal}`)
        return () => void layers.pop()
      },
    }
    const host = new MediaViewerHost({
      value,
      load: async () => {
        loads += 1
        // The real model with a stand-in for the kit's dialog (no DOM here).
        class NodeViewerModel extends MediaViewerModel {
          constructor(options: ConstructorParameters<typeof MediaViewerModel>[0]) {
            super({ ...options, dialog: () => ({ isOpen: signal(false), open: () => {}, close: () => {} }) })
          }
        }
        const module = { MediaViewerModel: NodeViewerModel, viewerItems, MediaViewer: () => null } as unknown as typeof import("./media-viewer-chunk")
        value.set(module)
        return module
      },
    }, keyboard)
    const media = fakeSources()
    const request = (n: number) => ({
      input: { rowId: `5:${n}` as MessageRowId, key: `photo:p${n}`, kind: "photo" as const, photo: photo(`p${n}`), video: undefined },
      rows: () => [photoRow(1), photoRow(2)],
      sources: media.sources,
    })
    const first = await host.open(request(1))
    expect(loads).toBe(1)
    expect(host.viewer.peek()).toBe(first)
    const second = await host.open(request(2))
    expect(loads).toBe(1)
    expect(host.viewer.peek()).toBe(second)
    expect(second?.index.peek()).toBe(1)
    // One modal layer while a viewer is open: the app's shortcuts wait under it.
    expect(layers).toEqual(["dialog:true"])
    host.dispose()
    expect(host.viewer.peek()).toBeUndefined()
    expect(layers).toEqual([])
  })
})

describe("attachments, loaded on the first file", () => {
  const fakeDrafts = () => {
    const added: Blob[] = []
    const items = signal<readonly never[]>([])
    const attachments = {
      chatId: "5" as ChatID,
      items,
      hasAttachments: signal(false),
      notice: signal<string | null>(null),
      add: (files: readonly Blob[]) => {
        added.push(...files)
      },
      wrapSend: () => async () => ({ status: "accepted" as const }),
    } as unknown as ComposerAttachments
    const placed: unknown[] = []
    let options: { placeRows?: (row: MessageRow) => unknown } | undefined
    const drafts: AttachmentDrafts = { forChat: () => attachments, dispose: () => {} }
    return { added, attachments, drafts, placed, options: () => options, set: (o: typeof options) => (options = o) }
  }

  it("is empty with the Attach button ready, loads the model on the first file, then sends through it", async () => {
    const fake = fakeDrafts()
    const value = signal<typeof import("./attachments-chunk") | undefined>(undefined)
    let loads = 0
    const session = new SessionAttachments({
      chunk: {
        value,
        load: async () => {
          loads += 1
          const module = {
            createAttachmentDrafts: (options: { placeRows?: (row: MessageRow) => unknown }) => {
              fake.set(options)
              return fake.drafts
            },
            attachmentSendErrorText: (reason: string) => (reason === "attachmentFailed" ? "An attachment failed." : null),
          } as unknown as typeof import("./attachments-chunk")
          value.set(module)
          return module
        },
      },
      client: {} as never,
      userId: "1" as UserID,
    })
    const lazy = session.forChat("5" as ChatID)
    expect(lazy.hasAttachments.peek()).toBe(false)
    expect(lazy.items.peek()).toEqual([])
    const textSends: string[] = []
    const send = lazy.wrapSend(async (request) => {
      textSends.push(request.text)
      return { status: "accepted" }
    })
    await send({ kind: "send", text: "hello" } as never)
    expect(textSends).toEqual(["hello"])
    expect(loads).toBe(0)

    const file = new Blob(["x"])
    lazy.add([file])
    await Promise.resolve()
    await Promise.resolve()
    expect(loads).toBe(1)
    expect(fake.added).toEqual([file])
    expect(lazy.inner.peek()).toBe(fake.attachments)
    expect(session.errorText("attachmentFailed")).toBe("An attachment failed.")

    // A composer created later for the same chat sees the same attachments at once.
    expect(session.forChat("5" as ChatID).inner.peek()).toBe(fake.attachments)

    // Optimistic media rows join the end of a registered window that is at the latest message.
    const atLatest = signal({ atLatest: true })
    const stop = session.registerWindow("5" as ChatID, { windowSub: 42, window: atLatest })
    const row = { chatId: "5" } as MessageRow
    expect(fake.options()?.placeRows?.(row)).toEqual({ row, appendTo: [42] })
    atLatest.set({ atLatest: false })
    expect(fake.options()?.placeRows?.(row)).toEqual({ row })
    stop()
    session.dispose()
  })
})

describe("attachments: the strip's view, the upload activity, files while editing", () => {
  it("starts the strip's view with the model, forwards the upload activity, and reports it through the chat's reporter", async () => {
    const activity = signal<UploadActivity | null>(null)
    const inner = {
      chatId: "5" as ChatID,
      items: signal<readonly never[]>([]),
      hasAttachments: signal(false),
      notice: signal<string | null>(null),
      activity,
      add: () => {},
      wrapSend: () => async () => ({ status: "accepted" as const }),
    } as unknown as ComposerAttachments
    const value = signal<typeof import("./attachments-chunk") | undefined>(undefined)
    const order: string[] = []
    let release: (() => void) | undefined
    const session = new SessionAttachments({
      chunk: {
        value,
        load: () =>
          new Promise((resolve) => {
            order.push("model")
            release = () => {
              const module = {
                createAttachmentDrafts: () => ({ forChat: () => inner, dispose: () => {} }),
                attachmentSendErrorText: () => null,
                followUploadActivity,
              } as unknown as typeof import("./attachments-chunk")
              value.set(module)
              resolve(module)
            }
          }),
      },
      client: {} as never,
      userId: "1" as UserID,
      loadStripView: () => void order.push("strip"),
    })
    const lazy = session.forChat("5" as ChatID)
    const reported: string[] = []
    const stop = session.followUploads(lazy.activity, {
      beginActivity: (kind) => {
        reported.push(`begin:${kind}`)
        return () => void reported.push(`end:${kind}`)
      },
    })
    // The first file starts the model and the strip's view together, not one after the other.
    lazy.add([new Blob(["x"])])
    expect(order).toEqual(["strip", "model"])
    expect(lazy.activity.peek()).toBeNull()
    release?.()
    await Promise.resolve()
    await Promise.resolve()
    // A sent photo still uploading: "sending photo" for the others, until it ends.
    activity.set("uploadingPhoto")
    expect(lazy.activity.peek()).toBe("uploadingPhoto")
    expect(reported).toEqual(["begin:uploadingPhoto"])
    activity.set(null)
    expect(reported).toEqual(["begin:uploadingPhoto", "end:uploadingPhoto"])
    // Disposing with the chat ends a running activity.
    activity.set("uploadingVideo")
    stop()
    expect(reported.slice(-2)).toEqual(["begin:uploadingVideo", "end:uploadingVideo"])
    session.dispose()
  })

  it("takes files dropped on the pane whatever the composer is doing: while editing they join the strip (the Mac's rule)", () => {
    const added: Blob[][] = []
    // The pane's drop target asks nothing of the composer: editing or not, a drop goes to the chat's attachments.
    const target = chatDropTarget({ add: (files) => void added.push([...files]) })
    const pane = new EventTarget() as EventTarget & { ownerDocument: { defaultView: EventTarget } }
    pane.ownerDocument = { defaultView: new EventTarget() }
    const detach = target.attach(pane as unknown as HTMLElement)
    const file = new File(["x"], "a.png", { type: "image/png" })
    const drop = new Event("drop", { bubbles: true, cancelable: true })
    Object.defineProperty(drop, "dataTransfer", { value: { types: ["Files"], files: [file], dropEffect: "none" } })
    pane.dispatchEvent(drop)
    expect(added).toEqual([[file]])
    detach()
    // Without attachments (no session loader), the pane takes no files.
    expect(chatDropTarget(undefined).active.peek()).toBe(false)
  })
})

describe("message content on the frame its row is on", () => {
  const strippedRow = (): MessageRow => {
    const row = photoRow(7)
    const info = { ...(row.media as { photo: PhotoInfo }).photo, stripped: new Uint8Array([1, 30, 40, 0xaa, 0xbb]) }
    return { ...row, media: { kind: "photo", photo: info } } as unknown as MessageRow
  }
  const element = () => {
    const props = new Map<string, string>()
    const style = {
      setProperty: (name: string, value: string | null) => void props.set(name, value ?? ""),
      removeProperty: (name: string) => {
        props.delete(name)
        return ""
      },
    }
    return { props, style }
  }

  it("the content environment exists in the same task the chunk arrives, with no other event", () => {
    const s = setup()
    const seen: (string | undefined)[] = []
    // What a slot's `useSignal(content.env)` subscribes to.
    const stop = effect(() => void seen.push(s.content.env.get() ? "env" : undefined))
    expect(seen).toEqual([undefined])
    s.arrive()
    expect(s.content.env.peek()).toBeDefined()
    expect(seen).toEqual([undefined, "env"])
    stop()
    s.content.dispose()
  })

  it("a photo row's placeholder paints its blurred preview before the chunk, with the URL the content view then uses", () => {
    const s = setup()
    const media = mediaModel(strippedRow())
    const preview = media && "preview" in media ? media.preview : undefined
    expect(preview).toBeDefined()
    // Before the chunk: the placeholder's preview layer (`MediaPlaceholder` in ChatMessages.tsx).
    const placeholder = element()
    const detach = s.content.previews.part(preview).attach(placeholder)
    const url = placeholder.props.get("background-image")
    expect(url).toMatch(/^url\("blob:/)
    // The chunk arrives: the content view's preview layer gets the same object URL (no reload, no flash).
    s.arrive()
    expect(s.content.env.peek()?.previews).toBe(s.content.previews)
    const view = element()
    s.content.env.peek()?.previews.part(preview).attach(view)
    expect(view.props.get("background-image")).toBe(url)
    detach()
    s.content.dispose()
  })
})
