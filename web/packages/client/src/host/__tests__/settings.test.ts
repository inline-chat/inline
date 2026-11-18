import {
  DialogNotificationSettings_Mode,
  NotificationSettings_Mode,
  type Update,
} from "@inline-chat/protocol/core"
import {
  rowKey,
  type DialogRow,
  type Intent,
  type SettingsRow,
} from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { chatPeer } from "../../testing/server-model/protocol"
import type { OutgoingFrame } from "../../testing/server-model"
import { DbObjectKind } from "../../database/models"
import { ModelHost } from "./model-host"

/**
 * Settings intents against the real host: each one durable (committed with
 * its optimistic rows before `accepted`), confirmed after a lost
 * acknowledgement, sent after going online, and sent after a restart.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

type Server = {
  archived?: boolean
  readAll: number
  settings: { mode?: NotificationSettings_Mode; silent?: boolean }
}

const boot = async (options: { online?: boolean } = {}) => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "unread" })
  const server: Server = { readAll: 0, settings: {} }
  mh.respond = (_method, input) => {
    switch (input.oneofKind) {
      case "updateDialogNotificationSettings": {
        const updates = mh.captureUpdates(() =>
          mh.model.setNotificationMode(10n, input.updateDialogNotificationSettings.notificationSettings?.mode),
        )
        return { result: { oneofKind: "updateDialogNotificationSettings", updateDialogNotificationSettings: { updates } } }
      }
      case "updateDialogArchived": {
        server.archived = input.updateDialogArchived.archived
        const update = {
          update: {
            oneofKind: "dialogArchived",
            dialogArchived: { peerId: chatPeer(10n), archived: server.archived },
          },
        } as Update
        return { result: { oneofKind: "updateDialogArchived", updateDialogArchived: { updates: [update] } } }
      }
      case "readMessages":
        if (input.readMessages.readActivity !== true) return undefined
        server.readAll += 1
        return { result: { oneofKind: "readMessages", readMessages: { updates: [] } } }
      case "updateUserSettings": {
        const patch = input.updateUserSettings.userSettings?.notificationSettings
        server.settings = { ...server.settings, ...patch }
        const update = {
          update: {
            oneofKind: "updateUserSettings",
            updateUserSettings: { settings: { notificationSettings: { ...server.settings } } },
          },
        } as Update
        return { result: { oneofKind: "updateUserSettings", updateUserSettings: { updates: [update] } } }
      }
      case "getUserSettings":
        return {
          result: {
            oneofKind: "getUserSettings",
            getUserSettings: { userSettings: { notificationSettings: { ...server.settings } } },
          },
        }
    }
    return undefined
  }
  await mh.seedDisk()
  await mh.start(options)
  mh.ui.subscribeTo(2, { kind: "sidebar", mode: "all" })
  mh.ui.subscribeTo(3, { kind: "userSettings" })
  mh.ui.subscribeTo(4, { kind: "sidebar", mode: "archived" })
  await mh.until(() => mh.ui.list(2).length === 1, "sidebar")
  return { mh, server }
}

/** The dialog, from whichever sidebar lists it (archiving moves it). */
const dialog = (mh: ModelHost) => (mh.ui.rows(2)[0] ?? mh.ui.rows(4)[0]) as DialogRow
const settings = (mh: ModelHost) => mh.ui.rows(3)[0] as SettingsRow | undefined
const hostRecords = (mh: ModelHost) => mh.disk.count("pending_transaction")

type Case = {
  name: string
  intent: Intent
  shown: (mh: ModelHost) => boolean
  applied: (mh: ModelHost, server: Server) => boolean
  resultKind: string
}

const cases: Case[] = [
  {
    name: "setDialogNotifications",
    intent: { kind: "setDialogNotifications", chatId: chat, mode: "mentions" },
    shown: (mh) => dialog(mh)?.notificationMode === "mentions",
    applied: (mh) => mh.model.dialogs.get(10n)?.notificationMode === DialogNotificationSettings_Mode.MENTIONS,
    resultKind: "updateDialogNotificationSettings",
  },
  {
    name: "setDialogArchived",
    intent: { kind: "setDialogArchived", chatId: chat, archived: true },
    shown: (mh) => dialog(mh)?.archived === true,
    applied: (_mh, server) => server.archived === true,
    resultKind: "updateDialogArchived",
  },
  {
    name: "readAll",
    intent: { kind: "readAll", chatId: chat },
    shown: (mh) => dialog(mh)?.unreadCount === 0,
    applied: (_mh, server) => server.readAll >= 1,
    resultKind: "readMessages",
  },
  {
    name: "updateUserSettings",
    intent: { kind: "updateUserSettings", patch: { notifications: { mode: "mentions", silent: true } } },
    shown: (mh) => settings(mh)?.notifications?.mode === "mentions" && settings(mh)?.notifications?.silent === true,
    applied: (_mh, server) =>
      server.settings.mode === NotificationSettings_Mode.MENTIONS && server.settings.silent === true,
    resultKind: "updateUserSettings",
  },
]

const isResultOf = (kind: string) => (frame: OutgoingFrame) =>
  frame.kind === "result" &&
  frame.message.body.oneofKind === "rpcResult" &&
  frame.message.body.rpcResult.result.oneofKind === kind

describe.each(cases)("$name", (scenario) => {
  it("is accepted after its commit, shows at once, and is confirmed", async () => {
    const { mh, server } = await boot()
    mh.transport.hold()
    mh.intent("s", scenario.intent)
    await mh.until(() => mh.ui.result("s")?.status === "accepted", "accepted")
    expect(scenario.shown(mh)).toBe(true)
    expect(await hostRecords(mh)).toBe(1)
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("s")).status).toBe("confirmed")
    expect(scenario.applied(mh, server)).toBe(true)
    expect(scenario.shown(mh)).toBe(true)
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })

  it("acknowledgement lost: retried after reconnect, confirmed, record gone", async () => {
    const { mh, server } = await boot()
    let armed = true
    mh.endpoint.interceptor = (frame) => {
      if (armed && isResultOf(scenario.resultKind)(frame)) {
        armed = false
        return "drop-and-disconnect"
      }
      return "deliver"
    }
    mh.intent("s", scenario.intent)
    expect((await mh.final("s")).status).toBe("confirmed")
    expect(scenario.applied(mh, server)).toBe(true)
    expect(scenario.shown(mh)).toBe(true)
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })

  it("offline: accepted and shown, sent when the network returns", async () => {
    const { mh, server } = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("s", scenario.intent)
    await mh.until(() => mh.ui.result("s")?.status === "accepted", "accepted")
    expect(scenario.shown(mh)).toBe(true)
    expect(scenario.applied(mh, server)).toBe(false)
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    expect((await mh.final("s")).status).toBe("confirmed")
    expect(scenario.applied(mh, server)).toBe(true)
  })

  it("survives a restart before it was sent: the next core sends it", async () => {
    const { mh, server } = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("s", scenario.intent)
    await mh.until(() => mh.ui.result("s")?.status === "accepted", "accepted")
    await mh.stop()
    expect(await hostRecords(mh)).toBe(1)
    await mh.start()
    mh.ui.subscribeTo(2, { kind: "sidebar", mode: "all" })
    mh.ui.subscribeTo(3, { kind: "userSettings" })
    mh.ui.subscribeTo(4, { kind: "sidebar", mode: "archived" })
    await mh.until(() => scenario.applied(mh, server), "sent by the next core")
    await mh.until(() => scenario.shown(mh), "shown by the next core")
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })
})

describe("outbox-backed dialog intents", () => {
  it("pin, follow and mark unread are durable through the realtime outbox", async () => {
    const { mh } = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("p", { kind: "setDialogPinned", chatId: chat, pinned: true })
    mh.intent("u", { kind: "markUnread", chatId: chat })
    await mh.until(
      () => mh.ui.result("p")?.status === "accepted" && mh.ui.result("u")?.status === "accepted",
      "accepted offline",
    )
    expect(dialog(mh)).toMatchObject({ pinned: true, unreadMark: true })
    expect(await mh.disk.count("pending_transaction")).toBe(2)
    expect(mh.ui.state.rows.get(rowKey("dialog", dialog(mh).id))).toBeDefined()
  })

  it("rejects malformed settings as data", async () => {
    const { mh } = await boot()
    mh.intent("bad1", { kind: "updateUserSettings", patch: { notifications: { mode: "loud" as never } } })
    mh.intent("bad2", { kind: "setDialogNotifications", chatId: chat, mode: "sometimes" as never })
    mh.intent("bad3", { kind: "setDialogArchived", chatId: chat, archived: "yes" as never })
    for (const tx of ["bad1", "bad2", "bad3"]) {
      expect(await mh.final(tx)).toMatchObject({ status: "rejected", reason: "invalid" })
    }
  })

  it("lists dialog folders pinned first, then by order", async () => {
    const mh = new ModelHost()
    running.push(mh)
    const folder = (id: string, order: string, pinnedOrder?: string) => ({
      kind: DbObjectKind.DialogFolder as const,
      id: id as never,
      title: `F${id}`,
      order,
      ...(pinnedOrder ? { pinnedOrder } : {}),
    })
    await mh.seedDisk([folder("1", "b"), folder("2", "a"), folder("3", "c", "a")])
    await mh.start()
    mh.ui.subscribeTo(2, { kind: "dialogFolders" })
    await mh.until(() => mh.ui.list(2).length === 3, "folders")
    expect(mh.ui.list(2)).toEqual([rowKey("folder", "3"), rowKey("folder", "2"), rowKey("folder", "1")])
  })

  it("fetches the account's settings once when the replica has none", async () => {
    const { mh } = await boot()
    await mh.synced()
    expect(mh.extraRpcs.filter((rpc) => rpc.input.oneofKind === "getUserSettings")).toHaveLength(1)
  })
})
