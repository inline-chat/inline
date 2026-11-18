import { describe, expect, it } from "vitest"
import { rowKey } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import { navigationCommandIds } from "../commands/navigation"
import { serializeWorkspace } from "../workspace/persistence"
import { Workspace } from "../workspace/workspace"
import { AccountSession, workspaceStorageKey, type AccountSessionOptions } from "./account-session"
import { chatRow, cid, coreResource, dialogRow, harness, keys, mid, uid, upserts, userRow } from "./test-support"

const memoryStorage = () => {
  const data = new Map<string, string>()
  return {
    data,
    getItem: (key: string) => data.get(key) ?? null,
    setItem: (key: string, value: string) => void data.set(key, value),
    removeItem: (key: string) => void data.delete(key),
  }
}

const setup = (extra: Partial<AccountSessionOptions> = {}) => {
  const h = harness()
  const connected: UserID[] = []
  const storage = memoryStorage()
  const session = new AccountSession({
    userId: uid(1),
    token: "secret",
    buildId: "b1",
    clock: h.time,
    storage,
    residentChats: 1,
    newClientKey: () => "55",
    connect: (userId) => {
      connected.push(userId)
      return h.connection()
    },
    ...extra,
  })
  const coreSub = h.sub((query) => query.kind === "core")
  const inboxSub = h.sub((query) => query.kind === "sidebar" && query.mode === "inbox")
  const allSub = h.sub((query) => query.kind === "sidebar" && query.mode === "all")
  return { ...h, session, connected, storage, coreSub, inboxSub, allSub }
}

describe("AccountSession", () => {
  it("connects for the user, says hello, starts the session and subscribes", () => {
    const s = setup()
    expect(s.connected).toEqual([uid(1)])
    expect(s.endpoint.posted.slice(0, 2)).toEqual([
      { kind: "hello", buildId: "b1", protocol: 0 },
      { kind: "session", action: "start", session: { userId: uid(1), token: "secret" } },
    ])
    expect(s.openSubs()).toEqual([
      { kind: "core" },
      { kind: "me" },
      { kind: "sidebar", mode: "inbox" },
      { kind: "sidebar", mode: "all" },
    ])
  })

  it("derives the user-facing status from the core resource with the reconnect delay", async () => {
    const s = setup()
    expect(s.session.status.peek()).toBe("starting")
    s.endpoint.patch({ resources: [{ sub: s.coreSub, value: coreResource({ connection: "connecting" }) }] })
    await s.flush()
    // Cold start: shown at once.
    expect(s.session.status.peek()).toBe("connecting")
    s.endpoint.patch({ resources: [{ sub: s.coreSub, value: coreResource() }] })
    await s.flush()
    expect(s.session.status.peek()).toBe("ready")
    s.endpoint.patch({ resources: [{ sub: s.coreSub, value: coreResource({ connection: "waitingForNetwork" }) }] })
    await s.flush()
    expect(s.session.status.peek()).toBe("ready")
    s.time.advance(1000)
    expect(s.session.status.peek()).toBe("waitingForNetwork")
    expect(s.session.connection.peek()).toBe("waitingForNetwork")
    s.endpoint.patch({ resources: [{ sub: s.coreSub, value: coreResource({ storage: "memory" }) }] })
    await s.flush()
    expect(s.session.status.peek()).toBe("storageNotKept")
    expect(s.session.revoked.peek()).toBe(false)
    s.endpoint.patch({
      resources: [{ sub: s.coreSub, value: coreResource({ phase: "signedOut", connection: "sessionRevoked" }) }],
    })
    await s.flush()
    expect(s.session.revoked.peek()).toBe(true)
  })

  it("exposes the signed-in user from the me query", async () => {
    const s = setup()
    const meSub = s.sub((query) => query.kind === "me")
    const me = userRow(1, "Mo")
    s.endpoint.patch({ rows: upserts(me), lists: [{ sub: meSub, op: "replace", keys: keys(me) }] })
    await s.flush()
    expect(s.session.me.peek()).toEqual(me)
  })

  it("restores the workspace saved for this account and saves navigation", () => {
    const storage = memoryStorage()
    const saved = new Workspace({ createId: () => "w", initial: { kind: "chat", chatId: cid(3) } })
    storage.setItem(workspaceStorageKey(uid(1)), serializeWorkspace(saved))
    storage.setItem(workspaceStorageKey(uid(2)), serializeWorkspace(new Workspace({ initial: { kind: "settings" } })))
    const s = setup({ storage })
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(3) })
    s.session.workspace.open({ kind: "chat", chatId: cid(4) })
    expect(storage.getItem(workspaceStorageKey(uid(1)))).toContain("/c/4")
  })

  it("registers the navigation commands and wires next and previous chat to the sidebar", async () => {
    const s = setup()
    const d1 = dialogRow(1)
    const d2 = dialogRow(2)
    s.endpoint.patch({
      rows: upserts(d1, d2, chatRow(1), chatRow(2)),
      lists: [{ sub: s.inboxSub, op: "replace", keys: keys(d1, d2) }],
    })
    await s.flush()
    expect(s.session.registry.run(navigationCommandIds.nextChat)).toBe(true)
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(1) })
    s.session.registry.run(navigationCommandIds.nextChat)
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(2) })
    s.session.registry.run(navigationCommandIds.back)
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(1) })

    const calls: string[] = []
    const detach = s.session.attachView({
      focusRegion: (region) => calls.push(`focus:${region}`),
      openQuickSearch: () => calls.push("search"),
      toggleSidebar: () => calls.push("sidebar"),
    })
    s.session.registry.run(navigationCommandIds.quickSearch)
    s.session.registry.run(navigationCommandIds.focusSidebar)
    detach()
    s.session.registry.run(navigationCommandIds.toggleSidebar)
    expect(calls).toEqual(["search", "focus:sidebar"])
  })

  it("counts the badge over every non-archived chat and gives chats their dialog", async () => {
    const s = setup()
    const dm = dialogRow(1, { peerUserId: uid(9), unreadCount: 3, open: false, readMaxId: mid(4) })
    s.endpoint.patch({
      rows: upserts(dm, chatRow(1, { peerUserId: uid(9) })),
      lists: [
        { sub: s.inboxSub, op: "replace", keys: [] },
        { sub: s.allSub, op: "replace", keys: keys(dm) },
      ],
    })
    await s.flush()
    // Not open, so not in the inbox, but still counted.
    expect(s.session.sidebar.items.peek()).toEqual([])
    expect(s.session.badgeCount.peek()).toBe(1)
    const lease = s.session.openChat(cid(1))
    expect(lease.model.readState.peek()).toEqual({ unreadCount: 3, readMaxId: mid(4) })
    lease.release()
  })

  it("keeps chats shown in a pane resident and releases others past the capacity", () => {
    const s = setup()
    s.session.workspace.open({ kind: "chat", chatId: cid(1) })
    s.session.openChat(cid(1)).release()
    s.session.openChat(cid(2)).release()
    s.session.openChat(cid(3)).release()
    expect(s.session.chats.resident.peek()).toEqual([cid(1), cid(3)])
    // The pane moves on: chat 1 is now the one recent chat kept beside it.
    s.session.workspace.open({ kind: "chat", chatId: cid(3) })
    expect(s.session.chats.resident.peek()).toEqual([cid(1), cid(3)])
    s.session.openChat(cid(4)).release()
    expect(s.session.chats.resident.peek()).toEqual([cid(3), cid(4)])
  })

  it("leaves nothing subscribed and closes the connection when ended", () => {
    const s = setup()
    s.session.openChat(cid(1))
    s.session.end({ erase: true })
    expect(s.endpoint.commands("session").at(-1)).toEqual({ kind: "session", action: "signOut" })
    expect(s.openSubs()).toEqual([])
    expect(s.endpoint.closed()).toBe(true)
    expect(s.session.registry.get(navigationCommandIds.nextChat)).toBeUndefined()
    expect(s.storage.data.has(workspaceStorageKey(uid(1)))).toBe(false)
    // Idempotent.
    s.session.dispose()
  })

  describe("signing out", () => {
    const running = async (s: ReturnType<typeof setup>) => {
      s.endpoint.patch({ resources: [{ sub: s.coreSub, value: coreResource() }] })
      await s.flush()
    }

    it("keeps the connection open until the core reports the replica erased", async () => {
      const s = setup()
      await running(s)
      const coreSub = s.coreSub
      const ended = s.session.end({ erase: true })
      expect(s.endpoint.commands("session").at(-1)).toEqual({ kind: "session", action: "signOut" })
      expect(s.session.disposed).toBe(true)
      // Everything but the core resource is released at once; the endpoint stays open.
      expect(s.openSubs()).toEqual([{ kind: "core" }])
      expect(s.endpoint.closed()).toBe(false)
      // A change that is not the end (the core telling the server first).
      s.endpoint.patch({ resources: [{ sub: coreSub, value: coreResource({ signingOut: true }) }] })
      await s.flush()
      expect(s.endpoint.closed()).toBe(false)

      s.endpoint.patch({
        resources: [{ sub: coreSub, value: coreResource({ phase: "signedOut", connection: "idle", erased: "complete" }) }],
      })
      await s.flush()
      await expect(ended).resolves.toBe("erased")
      expect(s.session.signOutOutcome).toBe("erased")
      expect(s.openSubs()).toEqual([])
      expect(s.endpoint.closed()).toBe(true)
      expect(s.time.pendingTimers()).toBe(0)
    })

    it("reports a failed erase", async () => {
      const s = setup()
      await running(s)
      const coreSub = s.coreSub
      const ended = s.session.end({ erase: true })
      s.endpoint.patch({
        resources: [{ sub: coreSub, value: coreResource({ phase: "signedOut", connection: "idle", erased: "failed" }) }],
      })
      await s.flush()
      await expect(ended).resolves.toBe("eraseFailed")
      expect(s.endpoint.closed()).toBe(true)
    })

    it("closes at the bound when the core does not answer, and records it", async () => {
      const s = setup({ signOutWaitMs: 5_000 })
      await running(s)
      const ended = s.session.end({ erase: true })
      s.time.advance(4_999)
      expect(s.endpoint.closed()).toBe(false)
      s.time.advance(1)
      await expect(ended).resolves.toBe("timedOut")
      expect(s.session.signOutOutcome).toBe("timedOut")
      expect(s.endpoint.closed()).toBe(true)
      expect(s.openSubs()).toEqual([])
    })

    it("does not wait after a revocation: the core erased before reporting it", async () => {
      const s = setup()
      await running(s)
      s.endpoint.patch({
        resources: [
          { sub: s.coreSub, value: coreResource({ phase: "signedOut", connection: "sessionRevoked", erased: "complete" }) },
        ],
      })
      await s.flush()
      await expect(s.session.end({ erase: true })).resolves.toBe("erased")
      expect(s.endpoint.closed()).toBe(true)
    })

    it("does not wait for a core that never reported a running session", async () => {
      const s = setup()
      await expect(s.session.end({ erase: true })).resolves.toBe("notRunning")
      expect(s.endpoint.closed()).toBe(true)
    })

    it("closes at once when disposed while waiting, and a repeated end returns the same result", async () => {
      const s = setup()
      await running(s)
      const ended = s.session.end({ erase: true })
      expect(s.session.end({ erase: true })).toBe(ended)
      s.session.dispose()
      await expect(ended).resolves.toBe("interrupted")
      expect(s.endpoint.closed()).toBe(true)
    })
  })

  it("sends from a chat model through the session's client", () => {
    const s = setup()
    const lease = s.session.openChat(cid(1))
    const handle = lease.model.send("hi", [], undefined)
    expect(handle.rowKey).toBe(rowKey("message", `${cid(1)}:r55`))
    expect(lease.model.row(handle.rowKey).peek()?.fromId).toBe(uid(1))
    lease.release()
  })
})
