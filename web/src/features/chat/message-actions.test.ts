import type { MessageRow, QueryDescriptor, WindowResource } from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { manualTime, signal } from "@inline/reactive"
import { message } from "@inline/reactive/testing"
import type { DialogController, PopoverController } from "@inline/ui"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { coreHarness, microtasks } from "../../app/test-fixtures"
import { MessageActionsController } from "../message/actions"
import { MessageActions, type ActionComposer, type MessageActionsOptions } from "./message-actions"

/**
 * Message actions against the real session (its `SessionActions`, a
 * resident chat over a scripted core): reply and edit reach the chat's
 * composer, Delete asks first and Cancel does not, the picker toggles the
 * viewer's reaction, and refusals become toasts in the model's tone.
 */

const me = "1" as UserID
const chat = "5" as ChatID
const theirs = message(5, 1, "from Ada", { fromId: "7" as UserID })
const own = message(5, 2, "from me", { fromId: me, out: true })
const sending = message(5, 3, "on its way", { fromId: me, out: true, state: "sending", clientKey: "k3" })

const windowResource = (): WindowResource => ({ kind: "window", hasOlder: false, hasNewer: false, atLatest: true, loading: "none" })

/** Stand-ins for the kit's top-layer controllers (no DOM in these tests). */
const layer = (onClose: () => void) => {
  const isOpen = signal(false)
  return {
    isOpen,
    open: () => isOpen.set(true),
    close: () => {
      if (!isOpen.peek()) return
      isOpen.set(false)
      onClose()
    },
  }
}

const standIns: NonNullable<MessageActionsOptions["layers"]> = (callbacks) => ({
  picker: layer(callbacks.pickerClosed) as unknown as PopoverController,
  confirm: layer(callbacks.confirmClosed) as unknown as DialogController,
})

/** Layers whose code arrives when the test says (the layers chunk over the network). */
const deferredLayers = () => {
  let arrive: (() => void) | undefined
  let fail: ((error: Error) => void) | undefined
  const factory: NonNullable<MessageActionsOptions["layers"]> = (callbacks) =>
    new Promise((resolve, reject) => {
      arrive = () => resolve(standIns(callbacks) as Awaited<ReturnType<typeof standIns>>)
      fail = reject
    })
  return { factory, arrive: () => arrive?.(), fail: () => fail?.(new Error("offline")) }
}

const setup = async (layers?: MessageActionsOptions["layers"]) => {
  const time = manualTime()
  const core = coreHarness(time)
  const session = new AccountSession({ userId: me, token: "t", connect: () => core.connection, clock: time })
  const lease = session.openChat(chat)
  const isWindow = (query: QueryDescriptor) => query.kind === "chatWindow" && query.chatId === chat
  core.list(isWindow, [theirs, own, sending])
  core.endpoint.patch({ resources: [{ sub: core.sub(isWindow), value: windowResource() }] })
  time.frame()
  await microtasks()
  const toasts: { title: string; tone?: string }[] = []
  const copied: string[] = []
  const actions = new MessageActions({
    session,
    copyText: (text) => void copied.push(text),
    toast: (input) => void toasts.push(input),
    origin: "https://app.test",
    layers: layers ?? standIns,
  })
  actions.attach()
  const calls: string[] = []
  const composer: ActionComposer = {
    composer: {
      setReply: (target) => void calls.push(`reply:${target?.messageId}`),
      startEdit: (target, content) => void calls.push(`edit:${target.messageId}:${content.text}`),
    },
    focus: () => {
      calls.push("focus")
      return true
    },
  }
  const intents = () => core.endpoint.commands("intent").map((command) => command.intent as { kind: string })
  return { time, core, session, lease, actions, toasts, copied, composer, calls, intents }
}

const run = (s: Awaited<ReturnType<typeof setup>>, row: MessageRow, id: string) => {
  const action = s.actions.actionsFor(row.id).find((candidate) => candidate.id === id)
  if (!action) throw new Error(`no ${id} action`)
  action.run({ rowId: row.id, via: "menu" })
}

describe("message actions", () => {
  it("reply and edit go to the composer of the pane showing the chat, and focus it", async () => {
    const s = await setup()
    const stop = s.actions.registerComposer(chat, s.composer)
    run(s, theirs, "reply")
    run(s, own, "edit")
    expect(s.calls).toEqual([`reply:${"1" as MessageID}`, "focus", `edit:${"2" as MessageID}:from me`, "focus"])
    // Not offered on someone else's message.
    expect(s.actions.actionsFor(theirs.id).map((action) => action.id)).not.toContain("edit")
    stop()
    run(s, theirs, "reply")
    expect(s.calls).toHaveLength(4)
  })

  it("asks before deleting, and deletes only on confirmation", async () => {
    const s = await setup()
    run(s, own, "delete")
    expect(s.actions.pendingDelete.peek()?.target.rowId).toBe(own.id)
    expect(s.actions.confirm?.isOpen.peek()).toBe(true)
    expect(s.intents().filter((intent) => intent.kind === "deleteMessages")).toHaveLength(0)

    s.actions.cancelDelete()
    expect(s.actions.pendingDelete.peek()).toBeUndefined()
    expect(s.intents().filter((intent) => intent.kind === "deleteMessages")).toHaveLength(0)

    run(s, own, "delete")
    s.actions.confirmDelete()
    expect(s.actions.confirm?.isOpen.peek() ?? false).toBe(false)
    expect(s.intents().filter((intent) => intent.kind === "deleteMessages")).toHaveLength(1)
  })

  it("asks before a keyboard delete too: the command goes through the same confirmation", async () => {
    const s = await setup()
    const deletes = () => s.intents().filter((intent) => intent.kind === "deleteMessages")
    s.session.actions.setFocused(own.id)
    // Mod+Backspace runs `message.delete` (the command bar and a native menu run the same command).
    expect(s.session.registry.run("message.delete", { source: "keyboard" })).toBe(true)
    expect(s.actions.pendingDelete.peek()?.target.rowId).toBe(own.id)
    expect(s.actions.pendingConfirm.peek()).toMatchObject({ title: "Delete message?", confirmLabel: "Delete", destructive: true })
    expect(s.actions.confirm?.isOpen.peek()).toBe(true)
    expect(deletes()).toHaveLength(0)

    s.actions.cancelPending()
    expect(deletes()).toHaveLength(0)
    expect(s.actions.pendingConfirm.peek()).toBeUndefined()

    s.session.registry.run("message.delete", { source: "keyboard" })
    s.actions.confirmPending()
    expect(deletes()).toHaveLength(1)
  })

  it("cancels a message still sending without asking, from the menu and the keyboard", async () => {
    const s = await setup()
    const deletes = () => s.intents().filter((intent) => intent.kind === "deleteMessages")
    run(s, sending, "cancel")
    expect(s.actions.confirm?.isOpen.peek() ?? false).toBe(false)
    expect(deletes()).toHaveLength(1)
    s.session.actions.setFocused(sending.id)
    s.session.registry.run("message.delete", { source: "keyboard" })
    expect(s.actions.confirm?.isOpen.peek() ?? false).toBe(false)
    expect(deletes()).toHaveLength(2)
  })

  it("asks through the session's confirmDelete hook, without replacing the session's delete", async () => {
    const s = await setup()
    expect(Object.hasOwn(s.session.actions, "delete")).toBe(false)
    expect(typeof s.actions.hooks().confirmDelete).toBe("function")
  })

  it("stops asking when detached: the hooks, the confirmation among them, are gone", async () => {
    const s = await setup()
    const detach = s.actions.attach()
    detach()
    s.session.actions.setFocused(own.id)
    s.session.registry.run("message.delete", { source: "keyboard" })
    expect(s.actions.confirm?.isOpen.peek() ?? false).toBe(false)
    expect(s.intents().filter((intent) => intent.kind === "deleteMessages")).toHaveLength(1)
  })

  it("asks anything else in the same alert: confirm runs it, Cancel declines it", async () => {
    const s = await setup()
    const calls: string[] = []
    s.actions.ask({ title: "Open link?", confirmLabel: "Open", run: () => calls.push("run"), cancel: () => calls.push("cancel") })
    expect(s.actions.pendingDelete.peek()).toBeUndefined()
    s.actions.cancelPending()
    s.actions.ask({ title: "Open link?", confirmLabel: "Open", run: () => calls.push("run"), cancel: () => calls.push("cancel") })
    s.actions.confirmPending()
    expect(calls).toEqual(["cancel", "run"])
  })

  it("the picker toggles the viewer's reaction on the message it opened for", async () => {
    const s = await setup()
    run(s, theirs, "react")
    expect(s.actions.pickerTarget.peek()?.rowId).toBe(theirs.id)
    s.actions.choose("👍")
    expect(s.actions.pickerTarget.peek()).toBeUndefined()
    expect(s.intents().at(-1)).toMatchObject({ kind: "react", messageId: theirs.messageId, emoji: "👍" })
  })

  it("the picker points where the chat's list says, keeps the row active while open, and lets go on close", async () => {
    let anchorOf: (() => unknown) | undefined
    const s = await setup((callbacks) => {
      anchorOf = callbacks.anchor
      return standIns(callbacks)
    })
    // The real row actions controller of the chat's list (no DOM here: its own anchor is null).
    const list = new MessageActionsController({ actionsFor: s.actions.actionsFor })
    const asked: string[] = []
    const reactButton = { x: 40, y: 300, width: 24, height: 24 }
    const detach = s.actions.registerPickerAnchors(chat, {
      setPickerAnchor: (rowId, rect) => {
        asked.push(rowId === null ? "clear" : `set:${rowId}`)
        list.setPickerAnchor(rowId, rect)
      },
      reactionAnchor: (rowId) => (rowId === theirs.id ? reactButton : list.reactionAnchor(rowId)),
    })
    // From the menu: at the row's Add Reaction button (`reactionAnchor`), and the row stays active.
    run(s, theirs, "react")
    expect(anchorOf?.()).toEqual(reactButton)
    expect(list.pickerAnchor.peek()).toEqual({ rowId: theirs.id, rect: reactButton })
    expect(list.isActive(theirs.id).peek()).toBe(true)
    // Closing lets go.
    s.actions.picker?.close()
    expect(list.pickerAnchor.peek()).toBeNull()
    // From a quick action: at the button's rectangle it was given.
    const quick = { x: 1, y: 2, width: 3, height: 4 }
    const target = s.session.actions.target(own.id)!
    s.actions.openPicker(target, quick)
    expect(anchorOf?.()).toEqual(quick)
    expect(list.pickerAnchor.peek()).toEqual({ rowId: own.id, rect: quick })
    s.actions.choose("👍")
    expect(list.pickerAnchor.peek()).toBeNull()
    // A list that goes away while its picker is open lets go too, and later pickers fall back to the row.
    s.actions.openPicker(target)
    detach()
    expect(list.pickerAnchor.peek()).toBeNull()
    expect(asked).toEqual([`set:${theirs.id}`, "clear", `set:${own.id}`, "clear", `set:${own.id}`, "clear"])
    list.dispose()
  })

  it("copies a message link as an app URL", async () => {
    const s = await setup()
    run(s, theirs, "copyLink")
    expect(s.copied).toEqual([`https://app.test/c/${chat}/m/${theirs.messageId}`])
  })

  it("shows a refusal as a toast in the tone the model gives it", async () => {
    const s = await setup()
    const hooks = s.actions.hooks()
    hooks.notify?.({ kind: "uncertain", tone: "warning", title: "Not confirmed yet", text: "…" })
    hooks.notify?.({ kind: "offline", tone: "error", title: "You're offline", text: "…" })
    expect(s.toasts.map((toast) => [toast.title, toast.tone])).toEqual([
      ["Not confirmed yet", "warning"],
      ["You're offline", "error"],
    ])
  })

  it("a delete asked before the layers' code arrives waits for it, then asks; nothing is deleted unasked", async () => {
    const layers = deferredLayers()
    const s = await setup(layers.factory)
    const deletes = () => s.intents().filter((intent) => intent.kind === "deleteMessages")
    s.session.actions.setFocused(own.id)
    s.session.registry.run("message.delete", { source: "keyboard" })
    expect(s.actions.pendingDelete.peek()?.target.rowId).toBe(own.id)
    expect(s.actions.confirm).toBeUndefined()
    expect(deletes()).toHaveLength(0)
    layers.arrive()
    await microtasks()
    expect(s.actions.confirm?.isOpen.peek()).toBe(true)
    s.actions.confirmPending()
    expect(deletes()).toHaveLength(1)
  })

  it("declining while the layers' code is on its way declines, and the alert does not open later", async () => {
    const layers = deferredLayers()
    const s = await setup(layers.factory)
    const calls: string[] = []
    s.actions.ask({ title: "Open link?", confirmLabel: "Open", run: () => calls.push("run"), cancel: () => calls.push("cancel") })
    s.actions.cancelPending()
    expect(calls).toEqual(["cancel"])
    layers.arrive()
    await microtasks()
    expect(s.actions.confirm?.isOpen.peek() ?? false).toBe(false)
  })

  it("the picker opened before its code arrives opens with it, for the same message", async () => {
    const layers = deferredLayers()
    const s = await setup(layers.factory)
    run(s, theirs, "react")
    expect(s.actions.pickerTarget.peek()?.rowId).toBe(theirs.id)
    layers.arrive()
    await microtasks()
    expect(s.actions.picker?.isOpen.peek()).toBe(true)
    s.actions.choose("👍")
    expect(s.intents().at(-1)).toMatchObject({ kind: "react", emoji: "👍" })
  })

  it("when the layers' code cannot load, the question is declined with a toast and a later one tries again", async () => {
    const layers = deferredLayers()
    const s = await setup(layers.factory)
    const deletes = () => s.intents().filter((intent) => intent.kind === "deleteMessages")
    run(s, own, "delete")
    layers.fail()
    await microtasks()
    expect(s.actions.pendingDelete.peek()).toBeUndefined()
    expect(s.toasts.at(-1)).toMatchObject({ title: "Couldn't open that", tone: "error" })
    run(s, own, "delete")
    layers.arrive()
    await microtasks()
    expect(s.actions.confirm?.isOpen.peek()).toBe(true)
    expect(deletes()).toHaveLength(0)
  })

  it("warming makes the layers before anyone asks; asking then opens in the same task", async () => {
    const layers = deferredLayers()
    const s = await setup(layers.factory)
    const warm = s.actions.loadLayers()
    layers.arrive()
    await warm
    expect(s.actions.layers.peek()).toBeDefined()
    run(s, own, "delete")
    expect(s.actions.confirm?.isOpen.peek()).toBe(true)
  })
})
