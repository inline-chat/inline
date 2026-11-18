/**
 * The boot snapshot through the whole runtime: one tab saves, the next start
 * paints from it before any core exists, the auth store confirms or rules it
 * out, the core's answer reconciles it, and every end of the account erases it.
 */

import { rowKeyOf } from "@inline/core-protocol"
import { effect } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { perfNames } from "../perf"
import { memoryStorage } from "../test-fixtures"
import { BOOT_SNAPSHOT_BUDGET, BOOT_SNAPSHOT_KEY } from "./format"
import { PENDING_TOKEN } from "./hinted-auth"
import { SNAPSHOT_IDLE_INTERVAL_MS } from "./saver"
import { account, answer, authStorage, cid, mid, openTab, uid, type Account, type Tab } from "./test-support"

const signedIn = (n = 7) => authStorage({ userId: uid(n), token: `t${n}` })

/** A tab that ran with the account's data open in chat 1, then was hidden: the snapshot is saved. */
const ranBefore = async (data: Account, auth = signedIn(), local = memoryStorage()) => {
  const tab = openTab(auth, { local })
  await tab.settle()
  const lease = tab.session()!.openChat(cid(1))
  answer(tab.cores[0]!, data)
  await tab.settle()
  const view = {
    items: tab.session()!.sidebar.items.peek(),
    item: tab.session()!.sidebar.items.peek().map((key) => tab.session()!.sidebar.item(key).peek()),
    rowKeys: lease.model.rowKeys.peek(),
    header: lease.model.header.peek(),
  }
  tab.fake.lifecycle.pageHide(false)
  return { tab, view, local, auth, lease }
}

const provisionalView = (tab: Tab) => {
  const session = tab.session()!
  const lease = session.openChat(cid(1))
  return {
    lease,
    view: {
      items: session.sidebar.items.peek(),
      item: session.sidebar.items.peek().map((key) => session.sidebar.item(key).peek()),
      rowKeys: lease.model.rowKeys.peek(),
      header: lease.model.header.peek(),
    },
  }
}

describe("boot snapshot: the gate", () => {
  it("paints the same view from the snapshot before the auth store answers and before any connector call", async () => {
    const data = account()
    const before = await ranBefore(data)
    let itemsAtConnect = -1
    const tab = openTab(before.auth, {
      local: before.local,
      onConnect: (runtime) => void (itemsAtConnect = runtime.app.session.peek()?.sidebar.items.peek().length ?? 0),
    })
    // Synchronously, in the task that created the runtime: no await yet.
    expect(tab.read.kind).toBe("snapshot")
    expect(tab.phase()).toBe("signedIn")
    expect(tab.authStore.getState().hasHydrated).toBe(false)
    expect(tab.runtime.bootSnapshot.peek()).toBe("provisional")
    const { lease, view } = provisionalView(tab)
    expect(view).toEqual(before.view)
    expect(lease.model.window.peek().ready).toBe(true)
    expect(tab.session()!.restoredFromSnapshot).toBe(true)
    expect(tab.cores).toHaveLength(0)

    // The auth store confirms: the core is connected with the real token, after the provisional state existed.
    await tab.settle()
    expect(tab.runtime.bootSnapshot.peek()).toBe("confirmed")
    expect(tab.cores).toHaveLength(1)
    expect(itemsAtConnect).toBe(data.dialogs.length)
    const core = tab.cores[0]!
    expect(core.endpoint.posted.slice(0, 2)).toEqual([
      { kind: "hello", buildId: expect.any(String), protocol: 0 },
      { kind: "session", action: "start", session: { userId: uid(7), token: "t7" } },
    ])
    expect(JSON.stringify(core.endpoint.posted)).not.toContain(PENDING_TOKEN)
    expect(core.openSubs().filter((query) => query.kind === "chatWindow")).toEqual([
      { kind: "chatWindow", chatId: cid(1), anchor: "unread" },
    ])
    lease.release()
  })

  it("reconciles with the core's answer: equal rows keep their identity, changed ones are replaced", async () => {
    const data = account()
    const before = await ranBefore(data)
    const tab = openTab(before.auth, { local: before.local })
    const session = tab.session()!
    const { lease } = provisionalView(tab)
    const [firstKey, secondKey] = session.sidebar.items.peek()
    const first = session.sidebar.item(firstKey!)
    const second = session.sidebar.item(secondKey!)
    const firstItem = first.peek()
    const firstMessage = lease.model.row(rowKeyOf(data.window[0]!)).peek()
    const renders = { first: 0, second: 0, list: 0, sidebar: 0 }
    const stops = [
      effect(() => void (first.get(), renders.first++)),
      effect(() => void (second.get(), renders.second++)),
      effect(() => void (lease.model.rowKeys.get(), renders.list++)),
      effect(() => void (session.sidebar.items.get(), renders.sidebar++)),
    ]
    await tab.settle()
    // The context's first snapshot is empty; nothing provisional goes.
    tab.cores[0]!.endpoint.deliver({ kind: "snapshot", snapshot: { revision: 1, rows: [], lists: [], resources: [], settled: [] } })
    await tab.settle()
    expect(session.sidebar.items.peek()).toHaveLength(data.dialogs.length)
    answer(tab.cores[0]!, data, (row) => (row.kind === "dialog" && row.id === "2" ? { ...row, unreadCount: 3 } : { ...row }))
    await tab.settle()
    expect(first.peek()).toBe(firstItem)
    expect(lease.model.row(rowKeyOf(data.window[0]!)).peek()).toBe(firstMessage)
    expect(second.peek()?.unreadCount).toBe(3)
    expect(renders).toEqual({ first: 1, second: 2, list: 1, sidebar: 1 })
    tab.paints.paint()
    expect(tab.metrics.has("snapshotReconciled")).toBe(true)
    expect(tab.metrics.measures().map((measure) => measure.name)).toContain(perfNames.snapshotReconciled)
    for (const stop of stops) stop()
    lease.release()
  })

  it("restores the window around the saved place and asks the core for that place", async () => {
    const data = account({ messages: 200 })
    const auth = signedIn()
    const first = openTab(auth)
    await first.settle()
    first.session()!.workspace.viewState.set({ kind: "chat", chatId: cid(1) }, { place: { messageId: mid(150), offset: 4 } })
    const lease = first.session()!.openChat(cid(1))
    answer(first.cores[0]!, data)
    await first.settle()
    first.fake.lifecycle.pageHide(false)
    lease.release()

    const tab = openTab(auth, { local: first.local })
    const restored = provisionalView(tab)
    expect(restored.view.rowKeys).toContain(rowKeyOf(data.window[149]!))
    await tab.settle()
    expect(tab.cores[0]!.openSubs().find((query) => query.kind === "chatWindow")).toEqual({
      kind: "chatWindow",
      chatId: cid(1),
      anchor: { around: mid(150) },
    })
    restored.lease.release()
  })

  it("tears the provisional UI down at once when the auth store says signed out, and erases the snapshot", async () => {
    const before = await ranBefore(account())
    before.auth.set(null)
    const tab = openTab(before.auth, { local: before.local })
    expect(tab.phase()).toBe("signedIn")
    await tab.authStore.ready
    // In the task the auth store answered in: the shell is gone.
    expect(tab.phase()).toBe("signingOut")
    expect(tab.runtime.bootSnapshot.peek()).toBe("discarded")
    expect(tab.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
    await tab.settle()
    await tab.runtime.idle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.cores).toHaveLength(0)
    expect(tab.runtime.signedOutReason.peek()).toBeUndefined()
  })

  it("tears it down for another user, whose session then connects normally", async () => {
    const before = await ranBefore(account())
    before.auth.set({ userId: uid(8), token: "t8" })
    const tab = openTab(before.auth, { local: before.local })
    expect(tab.session()?.userId).toBe(uid(7))
    await tab.settle()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.session()?.userId).toBe(uid(8))
    expect(tab.session()?.restoredFromSnapshot).toBe(false)
    expect(tab.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
    expect(tab.cores).toHaveLength(1)
    expect(tab.cores[0]!.endpoint.commands("session")).toEqual([
      { kind: "session", action: "start", session: { userId: uid(8), token: "t8" } },
    ])
    expect(tab.runtime.signedOutReason.peek()).toBeUndefined()
  })

  it("ignores a snapshot when the auth store already names another user", async () => {
    const before = await ranBefore(account())
    before.auth.set({ userId: uid(8), token: "t8" })
    const tab = openTab(before.auth, { local: before.local })
    await tab.settle()
    expect(tab.session()?.userId).toBe(uid(8))
    const next = openTab(before.auth, { local: before.local })
    expect(next.read.kind).toBe("none")
  })
})

describe("boot snapshot: saving", () => {
  it("writes once when the page hides (hidden, then pagehide), within the budget", async () => {
    const data = account({ chats: 60, messages: 60 })
    const tab = openTab(signedIn())
    await tab.settle()
    const lease = tab.session()!.openChat(cid(1))
    answer(tab.cores[0]!, data)
    await tab.settle()
    tab.fake.lifecycle.setVisible(false)
    tab.fake.lifecycle.pageHide(false)
    expect(tab.saves).toHaveLength(1)
    const save = tab.saves[0]!
    if ("erased" in save) throw new Error("expected a write")
    expect(save).toMatchObject({ reason: "hidden", written: true, dropped: [] })
    expect(save.chars).toBeLessThanOrEqual(BOOT_SNAPSHOT_BUDGET)
    expect(tab.local.getItem(BOOT_SNAPSHOT_KEY)?.length).toBe(save.chars)
    // Shown and hidden again: one more.
    tab.fake.lifecycle.setVisible(true)
    tab.fake.lifecycle.pageHide(false)
    expect(tab.saves).toHaveLength(2)
    lease.release()
  })

  it("saves in the idle lane at most every interval while things change", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    answer(tab.cores[0]!, account())
    await tab.settle()
    expect(tab.saves).toHaveLength(0)
    tab.time.advance(SNAPSHOT_IDLE_INTERVAL_MS)
    tab.time.idle()
    expect(tab.saves.map((save) => save.reason)).toEqual(["idle"])
    // Nothing changed since: the next interval writes nothing.
    tab.time.advance(SNAPSHOT_IDLE_INTERVAL_MS)
    tab.time.idle()
    expect(tab.saves).toHaveLength(1)
  })

  it("does not save before the core is ready", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    tab.fake.lifecycle.pageHide(false)
    expect(tab.saves).toEqual([])
    expect(tab.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
  })
})

describe("boot snapshot: erasing", () => {
  it("is erased on sign-out here", async () => {
    const before = await ranBefore(account())
    expect(before.local.getItem(BOOT_SNAPSHOT_KEY)).not.toBeNull()
    await before.tab.runtime.signOut()
    await before.tab.runtime.idle()
    expect(before.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
  })

  it("is erased when the core reports the session revoked", async () => {
    const before = await ranBefore(account())
    before.tab.cores[0]!.core({ connection: "sessionRevoked" })
    await before.tab.settle()
    await before.tab.runtime.idle()
    expect(before.tab.phase()).toBe("signedOut")
    expect(before.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
  })

  it("is erased when another tab signs out, even after this tab saved again", async () => {
    const before = await ranBefore(account())
    const other = openTab(before.auth, { local: before.local })
    await other.settle()
    await other.runtime.signOut()
    await other.runtime.idle()
    await before.tab.settle()
    await before.tab.runtime.idle()
    expect(before.tab.phase()).toBe("signedOut")
    expect(before.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
  })

  it.each([["outdated", { phase: "outdated" as const }], ["not kept", { storage: "memory" as const }], ["erased", { phase: "signedOut" as const }]])(
    "is erased when the core reports the replica %s, and not saved again",
    async (_name, resource) => {
      const before = await ranBefore(account())
      before.tab.cores[0]!.core(resource)
      await before.tab.settle()
      expect(before.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
      before.tab.fake.lifecycle.setVisible(true)
      before.tab.fake.lifecycle.pageHide(false)
      expect(before.local.getItem(BOOT_SNAPSHOT_KEY)).toBeNull()
    },
  )
})
