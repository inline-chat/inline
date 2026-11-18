import { UpdateComposeAction_ComposeAction as Action, type Update } from "@inline-chat/protocol/core"
import { COMPOSE_ACTION_RULE, rowKey, type ComposeResource } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { chatPeer } from "../../testing/server-model/protocol"
import { ModelHost } from "./model-host"

/**
 * Compose activity through the real host on fake time: outgoing typing is
 * throttled to one send per 3 s, ongoing actions refresh every 3 s until
 * stopped; incoming activity shows per chat, expires after 6 s, and is never
 * written to the replica.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addUser(3n, "Bo")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n, 3n] })
  mh.respond = (_method, input) =>
    input.oneofKind === "sendComposeAction"
      ? { result: { oneofKind: "sendComposeAction", sendComposeAction: {} } }
      : undefined
  await mh.seedDisk()
  await mh.start()
  return mh
}

const sent = (mh: ModelHost) =>
  mh.extraRpcs.flatMap((rpc) =>
    rpc.input.oneofKind === "sendComposeAction" ? [rpc.input.sendComposeAction.action ?? null] : [],
  )

const composing = (userId: bigint, action: Action): Update =>
  ({
    update: {
      oneofKind: "updateComposeAction",
      updateComposeAction: { userId, peerId: chatPeer(10n), action },
    },
  }) as Update

const activity = (mh: ModelHost, sub: number) => mh.ui.state.resources.get(sub) as ComposeResource | undefined

describe("outgoing compose actions", () => {
  it("sends typing at most once per refresh interval, and a stop only after something was sent", async () => {
    const mh = await boot()
    mh.intent("t1", { kind: "composeAction", chatId: chat, action: "typing" })
    expect((await mh.final("t1")).status).toBe("confirmed")
    await mh.synced()
    expect(sent(mh)).toEqual([Action.TYPING])
    await mh.time.advance(1_000)
    mh.intent("t2", { kind: "composeAction", chatId: chat, action: "typing" })
    await mh.synced()
    expect(sent(mh)).toEqual([Action.TYPING])
    await mh.time.advance(COMPOSE_ACTION_RULE.refreshMs)
    mh.intent("t3", { kind: "composeAction", chatId: chat, action: "typing" })
    await mh.synced()
    expect(sent(mh)).toEqual([Action.TYPING, Action.TYPING])
    mh.intent("t4", { kind: "composeAction", chatId: chat, action: null })
    await mh.synced()
    expect(sent(mh)).toEqual([Action.TYPING, Action.TYPING, null])
    mh.intent("t5", { kind: "composeAction", chatId: chat, action: null })
    await mh.synced()
    expect(sent(mh)).toHaveLength(3)
  })

  it("refreshes an upload every 3 s until it stops; typing does not replace it", async () => {
    const mh = await boot()
    mh.intent("u", { kind: "composeAction", chatId: chat, action: "uploadingPhoto" })
    await mh.synced()
    await mh.time.advance(COMPOSE_ACTION_RULE.refreshMs * 3 + 100)
    await mh.synced()
    mh.intent("t", { kind: "composeAction", chatId: chat, action: "typing" })
    await mh.synced()
    expect(sent(mh)).toEqual([Action.UPLOADING_PHOTO, Action.UPLOADING_PHOTO, Action.UPLOADING_PHOTO, Action.UPLOADING_PHOTO])
    mh.intent("s", { kind: "composeAction", chatId: chat, action: null })
    await mh.synced()
    await mh.time.advance(COMPOSE_ACTION_RULE.refreshMs * 2)
    await mh.synced()
    expect(sent(mh).at(-1)).toBeNull()
    expect(sent(mh)).toHaveLength(5)
  })

  it("rejects an unknown action as data", async () => {
    const mh = await boot()
    mh.intent("x", { kind: "composeAction", chatId: chat, action: "dancing" as never })
    expect(await mh.final("x")).toMatchObject({ status: "rejected", reason: "invalid" })
  })
})

describe("incoming compose actions", () => {
  it("shows who is typing per chat, refreshes, expires after 6 s, clears on NONE, and is never stored", async () => {
    const mh = await boot()
    const rawBefore = await mh.disk.count("deferred_update")
    mh.ui.subscribeTo(2, { kind: "composeActions", chatId: chat })
    mh.ui.subscribeTo(3, { kind: "composeActions" })
    await mh.until(() => activity(mh, 2) != null, "subscribed")
    await mh.settleUntil(mh.transport.pushUpdates([composing(2n, Action.TYPING), composing(3n, Action.UPLOADING_VIDEO)]))
    await mh.until(() => activity(mh, 2)?.activities.length === 2, "two composing")
    expect(activity(mh, 2)!.activities).toEqual([
      { chatId: chat, userId: "2", action: "typing" },
      { chatId: chat, userId: "3", action: "uploadingVideo" },
    ])
    expect(mh.ui.list(2)).toEqual([rowKey("user", "2"), rowKey("user", "3")])
    expect(activity(mh, 3)!.activities).toHaveLength(2)

    // Bo refreshes at 4 s; Ada does not and expires at 6 s.
    await mh.time.advance(4_000)
    await mh.settleUntil(mh.transport.pushUpdates([composing(3n, Action.UPLOADING_VIDEO)]))
    await mh.time.advance(2_500)
    await mh.until(() => activity(mh, 2)?.activities.length === 1, "Ada expired")
    expect(activity(mh, 2)!.activities[0]!.userId).toBe("3")

    await mh.settleUntil(mh.transport.pushUpdates([composing(3n, Action.NONE)]))
    await mh.until(() => activity(mh, 2)?.activities.length === 0, "Bo stopped")
    await mh.synced()
    expect(await mh.disk.count("deferred_update")).toBe(rawBefore)
  })

  it("a new message from the composer ends their typing", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(2, { kind: "composeActions", chatId: chat })
    await mh.settleUntil(mh.transport.pushUpdates([composing(2n, Action.TYPING)]))
    await mh.until(() => activity(mh, 2)?.activities.length === 1, "typing")
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "done" })
    await mh.until(() => activity(mh, 2)?.activities.length === 0, "cleared by the message")
  })
})
