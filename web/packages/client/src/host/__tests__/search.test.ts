import { rowKey, type SearchResource } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * Local message search through the host: requests carried as
 * subscriptions, the index state on the `core` resource, cancellation by
 * resubscribing or unsubscribing, and the engine stopping before the store
 * closes.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

/** A replica whose index must be rebuilt (an older normalizer), as after an upgrade. */
const boot = async () => {
  const mh = new ModelHost({ host: { searchStartDelayMs: 1_000 } })
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "deploy the release today" })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "release notes are ready" })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "deploy went fine" })
  await mh.seedDisk()
  await mh.disk.exec(
    `UPDATE inline_replica_metadata SET value = '{"version":0,"state":"ready"}' WHERE key = 'message_search'`,
  )
  await mh.start()
  return mh
}

const result = (mh: ModelHost, sub: number) => mh.ui.state.resources.get(sub) as SearchResource | undefined
const done = (mh: ModelHost, sub: number) => {
  const value = result(mh, sub)
  return value?.status === "done" ? value.result : undefined
}

describe("local message search", () => {
  it("says the index is incomplete during the backfill, then returns hits with ranges and the chat's title", async () => {
    const mh = await boot()
    expect(mh.ui.core(1)?.searchIndex).toBeUndefined()
    mh.ui.subscribeTo(5, { kind: "searchMessages", request: { query: "deploy" } })
    await mh.until(() => done(mh, 5) != null, "first answer")
    expect(done(mh, 5)).toMatchObject({ kind: "messages", indexComplete: false })

    await mh.until(() => mh.ui.core(1)?.searchIndex?.state === "ready", "indexed")
    mh.ui.subscribeTo(5, { kind: "searchMessages", request: { query: "deploy" } })
    await mh.until(() => {
      const answer = done(mh, 5)
      return answer?.kind === "messages" && answer.indexComplete
    }, "second answer")
    const answer = done(mh, 5)!
    if (answer.kind !== "messages") throw new Error("kind")
    expect(answer.hits.map((hit) => hit.snippet)).toEqual(["deploy went fine", "deploy the release today"])
    expect(answer.hits[0]).toMatchObject({ chatId: chat, chatTitle: "Design", fromId: "2", snippetRanges: [[0, 6]] })
    expect(mh.ui.state.rows.has(rowKey("chat", chat))).toBe(false)
  })

  it("finds in a chat newest first with ranges, and counts", async () => {
    const mh = await boot()
    await mh.until(() => mh.ui.core(1)?.searchIndex?.state === "ready", "indexed")
    mh.ui.subscribeTo(5, { kind: "findInChat", request: { chatId: chat, query: "release" } })
    mh.ui.subscribeTo(6, { kind: "countMessages", request: { query: "deploy" } })
    await mh.until(() => done(mh, 5) != null && done(mh, 6) != null, "answers")
    const find = done(mh, 5)!
    if (find.kind !== "findInChat") throw new Error("kind")
    expect(find.hits.map((hit) => hit.text)).toEqual(["release notes are ready", "deploy the release today"])
    expect(find.hits[1]!.ranges).toEqual([[11, 18]])
    expect(find).toMatchObject({ hasOlder: false, hasNewer: false, indexComplete: true })
    expect(done(mh, 6)).toEqual({ kind: "count", count: 2, capped: false, indexComplete: true })
  })

  it("a replaced or cancelled request never delivers its result", async () => {
    const mh = await boot()
    await mh.until(() => mh.ui.core(1)?.searchIndex?.state === "ready", "indexed")
    const from = mh.ui.patches.length
    mh.ui.subscribeTo(5, { kind: "searchMessages", request: { query: "deploy" } })
    mh.ui.subscribeTo(5, { kind: "searchMessages", request: { query: "notes" } })
    mh.ui.subscribeTo(7, { kind: "countMessages", request: { query: "deploy" } })
    mh.ui.post({ kind: "unsubscribe", sub: 7 })
    await mh.until(() => done(mh, 5) != null, "answer")
    await mh.synced()
    const delivered = mh.ui.patches.slice(from).flatMap((patch) => patch.resources)
    const answers = delivered.filter((change) => change.value.kind === "search" && change.value.status === "done")
    expect(answers.map((change) => change.sub)).toEqual([5])
    const answer = done(mh, 5)!
    expect(answer.kind === "messages" && answer.hits.map((hit) => hit.snippet)).toEqual(["release notes are ready"])
  })

  it("answers malformed requests as data", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(5, { kind: "findInChat", request: { chatId: "x" as never, query: "deploy" } })
    mh.ui.subscribeTo(6, { kind: "searchMessages", request: { query: "deploy", cursor: "not-a-cursor" } })
    await mh.until(() => result(mh, 5)?.status === "failed" && result(mh, 6)?.status === "failed", "failed")
    expect(result(mh, 5)).toEqual({ kind: "search", status: "failed", reason: "invalid" })
    expect(result(mh, 6)).toEqual({ kind: "search", status: "failed", reason: "invalid" })
  })

  it("sign-out stops the engine before the store closes", async () => {
    const mh = await boot()
    await mh.until(() => mh.ui.core(1)?.searchIndex?.state === "ready", "indexed")
    const account = (mh.host as unknown as {
      account: { search: { engine: { stop(): Promise<void> } }; db: { closePersistence(): Promise<void> } }
    }).account
    const order: string[] = []
    const stop = account.search.engine.stop.bind(account.search.engine)
    account.search.engine.stop = async () => {
      order.push("search.stop")
      await stop()
    }
    const close = account.db.closePersistence.bind(account.db)
    account.db.closePersistence = async () => {
      order.push("store.close")
      await close()
    }
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(order).toEqual(["search.stop", "store.close"])
    expect(mh.ui.core(1)?.searchIndex).toBeUndefined()
  })
})
