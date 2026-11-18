import type { ChatID, UserID } from "@inline/ids"
import { manualTime } from "@inline/reactive"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { chatInfoMediaRows, chatInfoOptions } from "./chat-info-pane"
import { paneViewKind } from "./pane-registry"
import { coreHarness } from "./test-fixtures"

/**
 * The `chatInfo` destination: the registry maps it to its own pane (no
 * longer the unbuilt one), and the model options act on the pane that shows
 * it: a tab change replaces the destination there (no history entry), a
 * participant opens their profile in that pane.
 */

const chat = "5" as ChatID
const me = "1" as UserID

const setup = () => {
  const time = manualTime()
  const core = coreHarness(time)
  const session = new AccountSession({ userId: me, token: "t", connect: () => core.connection, clock: time })
  const paneId = session.workspace.focusedPaneId.peek()
  session.workspace.open({ kind: "chat", chatId: chat })
  session.workspace.open({ kind: "chatInfo", chatId: chat })
  return { session, paneId }
}

const entries = (s: ReturnType<typeof setup>) => s.session.workspace.pane(s.paneId)?.entries.map((entry) => entry.destination) ?? []

describe("chat info pane", () => {
  it("maps the chatInfo destination, with or without a tab, to the chat info pane", () => {
    expect(paneViewKind({ kind: "chatInfo", chatId: chat })).toBe("chatInfo")
    expect(paneViewKind({ kind: "chatInfo", chatId: chat, tab: "participants" })).toBe("chatInfo")
  })

  it("replaces the pane's destination on a tab change and opens profiles in the same pane", () => {
    const s = setup()
    const options = chatInfoOptions({ session: s.session, paneId: s.paneId, chatId: chat })
    expect(options.chatId).toBe(chat)
    expect(options.viewerId).toBe(me)
    const before = entries(s).length

    options.onTabChange?.("participants")
    expect(entries(s)).toHaveLength(before)
    expect(s.session.workspace.destination(s.paneId)).toEqual({ kind: "chatInfo", chatId: chat, tab: "participants" })
    options.onTabChange?.(undefined)
    expect(s.session.workspace.destination(s.paneId)).toEqual({ kind: "chatInfo", chatId: chat })

    options.onOpenProfile("3" as UserID)
    expect(s.session.workspace.destination(s.paneId)).toEqual({ kind: "user", userId: "3" })
    expect(entries(s)).toHaveLength(before + 1)
  })

  it("passes the destination's tab and the session's offline state", () => {
    const s = setup()
    const options = chatInfoOptions({ session: s.session, paneId: s.paneId, chatId: chat, tab: "media" })
    expect(options.tab).toBe("media")
    expect(options.offline?.peek()).toBe(s.session.health.peek().kind === "offline")
    expect(options.dialog).toBe(s.session.dialogFor(chat))
  })

  it("hands the media tabs the session's media layer, the viewer with the Media tab's rows, downloads and links; member outcomes become toasts", () => {
    const s = setup()
    const sources = { photo: () => undefined } as never
    let made = 0
    const opened: { input: unknown; rows: readonly unknown[]; sources: unknown }[] = []
    const downloads: unknown[] = []
    const links: string[] = []
    const toasts: unknown[] = []
    const keys = [`message:${chat}:3`, `message:${chat}:2`] as never[]
    const model = { mediaTab: (tab: string) => ({ ids: { peek: () => (tab === "media" ? keys : []) } }) } as never
    const rows = new Map<string, unknown>([
      [`message:${chat}:3`, { kind: "message", id: `${chat}:3` }],
      [`message:${chat}:2`, { kind: "message", id: `${chat}:2` }],
    ])
    const peek = s.session.client.store.peekRow.bind(s.session.client.store)
    s.session.client.store.peekRow = ((key: string) => rows.get(key) ?? peek(key as never)) as never
    const options = chatInfoOptions({
      session: s.session,
      paneId: s.paneId,
      chatId: chat,
      model: () => model,
      toast: (toast) => void toasts.push(toast),
      media: {
        sources: () => {
          made += 1
          return sources
        },
        openMedia: (input, rowsOf, given) => void opened.push({ input, rows: rowsOf(), sources: given }),
        download: (input) => void downloads.push(input),
        openLink: (url) => void links.push(url),
      },
    })
    expect(options.media?.sources).toBe(sources)
    expect(made).toBe(1)
    const input = { rowId: `${chat}:2`, key: "photo:9", kind: "photo" } as never
    options.media?.onOpenMedia?.(input)
    // The viewer steps through the Media tab's rows, oldest first, over the same sources.
    expect(opened).toEqual([{ input, rows: [rows.get(`message:${chat}:2`), rows.get(`message:${chat}:3`)], sources }])
    options.media?.onDownload?.({ rowId: `${chat}:2`, media: {} } as never)
    expect(downloads).toHaveLength(1)
    options.media?.onOpenLink?.("https://example.com")
    expect(links).toEqual(["https://example.com"])
    options.onNotice?.({ kind: "done", title: "Added Ada", text: "" } as never)
    options.onNotice?.({ kind: "failed", title: "Couldn't remove Ada", text: "Try again.", tone: "error" } as never)
    expect(toasts).toEqual([
      { id: "chat-info-members", title: "Added Ada", tone: "neutral" },
      { id: "chat-info-members", title: "Couldn't remove Ada", description: "Try again.", tone: "error" },
    ])
    expect(chatInfoMediaRows(undefined, () => undefined)).toEqual([])
  })
})
