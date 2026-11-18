import type { MediaRef, PhotoInfo, VideoInfo } from "@inline/core-protocol"
import type { ChatID, FileID, MessageID, PhotoID } from "@inline/ids"
import { effect } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import type { MediaOwner, MediaSource, MediaSourceState } from "../content/sources"
import { safeMediaType } from "./object-urls"
import { createCoreMediaSources, MEDIA_GRACE_MS } from "./sources"
import { fakeBlobUrls, fakeElement, fakeObservers, manualQueue, scriptedCore } from "./test-support"

const chat = "7" as ChatID
const owner = (messageId: number, extra: Partial<MediaOwner> = {}): MediaOwner => ({
  chatId: chat,
  messageId: String(messageId) as MessageID,
  attachmentId: undefined,
  clientKey: undefined,
  state: "sent",
  ...extra,
})

const photo = (file = "F1"): PhotoInfo => ({
  id: "1" as PhotoID,
  fileUniqueId: file,
  sizes: [
    { type: "b", width: 160, height: 120, size: 4_000, fileUniqueId: `${file}b` },
    { type: "f", width: 1280, height: 960, size: 90_000, fileUniqueId: `${file}f` },
  ],
})

const box = { width: 320, height: 240 }

const setup = (options: { graceMs?: number; idleLimit?: number } = {}) => {
  const core = scriptedCore()
  const urls = fakeBlobUrls()
  const defer = manualQueue()
  const frame = manualQueue()
  const observers = fakeObservers()
  const sources = createCoreMediaSources({
    client: core.client,
    urls,
    clock: core.time,
    defer: defer.run,
    frame: frame.run,
    pixelRatio: () => 2,
    createObserver: observers.create,
    ...options,
  })
  /** Attach a box for a source and decide (the commit, then its microtask). */
  const show = (source: MediaSource, name = "box") => {
    const element = fakeElement(name)
    const release = source.part!.attach(element)
    defer.flush()
    return { element, release }
  }
  const state = (source: MediaSource): MediaSourceState => source.state.peek()
  return { core, urls, defer, frame, observers, sources, show, state }
}

const blob = (bytes = 10, type = "image/jpeg") => new Blob([new Uint8Array(bytes)], { type })

describe("CoreMediaSources: sharing", () => {
  it("asks the core for the variant that covers the box, and shares one subscription and URL across ten rows", () => {
    const { core, urls, sources, show, state } = setup()
    const shown = Array.from({ length: 10 }, (_, index) => {
      // Ten rows: the same file in ten messages (a forward, say).
      const source = sources.photo(photo(), box, owner(100 + index))
      return { source, ...show(source, `row ${index}`) }
    })
    expect(new Set(shown.map((row) => row.source)).size).toBe(1)
    const subs = core.mediaSubs()
    expect(subs).toHaveLength(1)
    expect(subs[0]!.ref).toEqual({ kind: "message", chatId: chat, messageId: "100", size: "f" })
    core.media(subs[0]!.sub, { state: "ready", blob: blob(), size: 10 })
    expect(urls.live.size).toBe(1)
    for (const row of shown) expect(state(row.source)).toEqual({ status: "ready", url: urls.created[0] })
    for (const row of shown) row.release()
    core.time.advance(MEDIA_GRACE_MS)
    expect(urls.live.size).toBe(0)
    expect(core.mediaSubs()).toHaveLength(0)
    expect(urls.strays).toEqual([])
  })

  it("keeps the subscription and URL through the grace period, so a row coming back shows at once", () => {
    const { core, urls, sources, show, state } = setup()
    const source = sources.photo(photo(), box, owner(1))
    const first = show(source)
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: blob() })
    const url = urls.created[0]
    first.release()
    core.time.advance(MEDIA_GRACE_MS - 1)
    // The row comes back: same source object, same URL, no new subscription.
    const again = sources.photo(photo(), box, owner(1))
    expect(again).toBe(source)
    const second = show(again)
    expect(state(again)).toEqual({ status: "ready", url })
    expect(core.endpoint.commands("subscribe")).toHaveLength(1)
    core.time.advance(MEDIA_GRACE_MS * 3)
    expect(urls.live.size).toBe(1)
    second.release()
    core.time.advance(MEDIA_GRACE_MS)
    expect(urls.live.size).toBe(0)
    expect(core.endpoint.commands("unsubscribe")).toHaveLength(1)
  })

  it("a detach and attach in the same task (a remount) keeps the subscription and URL", () => {
    const { core, urls, sources, defer, state } = setup()
    const source = sources.photo(photo(), box, owner(1))
    const element = fakeElement("box")
    const release = source.part!.attach(element)
    defer.flush()
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: blob() })
    release()
    const releaseAgain = source.part!.attach(element)
    defer.flush()
    expect(core.endpoint.commands("subscribe")).toHaveLength(1)
    expect(core.endpoint.commands("unsubscribe")).toHaveLength(0)
    expect(state(source)).toEqual({ status: "ready", url: urls.created[0] })
    releaseAgain()
    core.time.advance(MEDIA_GRACE_MS)
    expect(urls.live.size).toBe(0)
    expect(urls.strays).toEqual([])
  })

  it("drops the oldest released entry beyond the idle limit", () => {
    const { core, urls, sources, show } = setup({ idleLimit: 2 })
    const rows = [1, 2, 3].map((n) => {
      const source = sources.photo(photo(`F${n}`), box, owner(n))
      const shown = show(source)
      core.media(core.mediaSubs((ref) => ref.kind === "message" && ref.messageId === String(n))[0]!.sub, {
        state: "ready",
        blob: blob(),
      })
      return shown
    })
    expect(urls.live.size).toBe(3)
    for (const row of rows) row.release()
    // Three waiting, limit two: the first released went at once.
    expect(urls.live.size).toBe(2)
    expect(core.mediaSubs().map((sub) => (sub.ref as { messageId: string }).messageId)).toEqual(["2", "3"])
  })

  it("an entry a render made but no box held goes after the grace period", () => {
    const { core, sources } = setup()
    sources.photo(photo(), box, owner(1))
    expect(sources.stats().entries).toBe(1)
    expect(core.mediaSubs()).toHaveLength(0)
    core.time.advance(MEDIA_GRACE_MS)
    expect(sources.stats().entries).toBe(0)
  })
})

describe("CoreMediaSources: URLs", () => {
  it("never makes a URL for absent, queued, downloading or failed, and revokes when ready ends", () => {
    const { core, urls, sources, show, state } = setup()
    const source = sources.photo(photo(), box, owner(1))
    show(source)
    const sub = core.mediaSubs()[0]!.sub
    core.media(sub, { state: "absent" })
    expect(state(source)).toEqual({ status: "pending" })
    core.media(sub, { state: "queued", totalBytes: 100 })
    core.media(sub, { state: "downloading", receivedBytes: 25, totalBytes: 100 })
    expect(state(source)).toEqual({ status: "pending", progress: 0.25 })
    expect(sources.detail(source)?.peek()).toMatchObject({ phase: "downloading", receivedBytes: 25, totalBytes: 100 })
    core.media(sub, { state: "failed", failure: "network" })
    expect(state(source)).toEqual({ status: "failed" })
    expect(urls.created).toEqual([])
    core.media(sub, { state: "ready", blob: blob() })
    expect(urls.live.size).toBe(1)
    core.media(sub, { state: "failed", failure: "notFound" })
    expect(urls.live.size).toBe(0)
    expect(state(source)).toEqual({ status: "failed" })
  })

  it("replaces the URL when a later resource carries a different blob, and keeps it for the same one", () => {
    const { core, urls, sources, show, state } = setup()
    const source = sources.photo(photo(), box, owner(1))
    show(source)
    const sub = core.mediaSubs()[0]!.sub
    const first = blob()
    core.media(sub, { state: "ready", blob: first, size: 10 })
    core.media(sub, { state: "ready", blob: first, size: 10 })
    expect(urls.created).toHaveLength(1)
    core.media(sub, { state: "ready", blob: blob(12), size: 12 })
    expect(urls.created).toHaveLength(2)
    expect(urls.revoked).toEqual([urls.created[0]])
    expect(state(source)).toEqual({ status: "ready", url: urls.created[1] })
  })

  it("gives URLs only safe media types: SVG and HTML bytes become opaque", () => {
    const { core, urls, sources, show } = setup()
    const source = sources.photo(photo(), box, owner(1))
    show(source)
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: blob(10, "image/svg+xml") })
    const made = [...urls.live.values()][0]!
    expect(made.type).toBe("application/octet-stream")
    expect(safeMediaType("text/html")).toBe("application/octet-stream")
    expect(safeMediaType("image/png")).toBe("image/png")
    expect(safeMediaType("video/mp4; codecs=avc1")).toBe("video/mp4")
  })

  it("dispose revokes every URL and unsubscribes everything", () => {
    const { core, urls, sources, show } = setup()
    for (const n of [1, 2, 3]) {
      show(sources.photo(photo(`F${n}`), box, owner(n)))
    }
    for (const { sub } of core.mediaSubs()) core.media(sub, { state: "ready", blob: blob() })
    expect(urls.live.size).toBe(3)
    sources.dispose()
    expect(urls.live.size).toBe(0)
    expect(core.mediaSubs()).toHaveLength(0)
    expect(urls.strays).toEqual([])
  })
})

describe("CoreMediaSources: retry, open, fallbacks", () => {
  it("retry asks again with priority opened and keeps what is shown until the new answer", () => {
    const { core, urls, sources, show, state } = setup()
    const source = sources.photo(photo(), box, owner(1))
    show(source)
    const first = core.mediaSubs()[0]!
    expect(first.priority).toBe("visible")
    core.media(first.sub, { state: "failed", failure: "network" })
    source.retry()
    const second = core.mediaSubs().find((sub) => sub.sub !== first.sub)!
    expect(second.priority).toBe("opened")
    // The old subscription is still open until the new one answers.
    expect(core.mediaSubs()).toHaveLength(2)
    core.media(second.sub, { state: "absent" })
    expect(state(source)).toEqual({ status: "failed" })
    core.media(second.sub, { state: "ready", blob: blob() })
    expect(core.mediaSubs().map((sub) => sub.sub)).toEqual([second.sub])
    expect(state(source)).toEqual({ status: "ready", url: urls.created[0] })
  })

  it("a retry after the element failed to decode makes a fresh URL even for the same blob", () => {
    const { core, urls, sources, show } = setup()
    const source = sources.photo(photo(), box, owner(1))
    show(source)
    const bytes = blob()
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: bytes })
    source.retry()
    const next = core.mediaSubs().at(-1)!
    core.media(next.sub, { state: "ready", blob: bytes })
    expect(urls.created).toHaveLength(2)
    expect(urls.live.size).toBe(1)
  })

  it("open upgrades the claim to opened", () => {
    const { core, sources, show } = setup()
    const source = sources.photo(photo(), box, owner(1))
    show(source)
    sources.open(source)
    expect(core.mediaSubs().at(-1)!.priority).toBe("opened")
    sources.open(source)
    expect(core.endpoint.commands("subscribe")).toHaveLength(2)
  })

  it("media without an owner, or without a file ID, falls back to the row's URL", () => {
    const { core, sources } = setup()
    const cdn: PhotoInfo = {
      id: "2" as PhotoID,
      sizes: [{ type: "f", width: 100, height: 100, cdnUrl: "https://cdn.example/x.jpg" }],
    }
    expect(sources.photo(cdn, box).state.peek()).toEqual({ status: "ready", url: "https://cdn.example/x.jpg" })
    expect(sources.photo(cdn, box, owner(1)).state.peek()).toEqual({ status: "ready", url: "https://cdn.example/x.jpg" })
    expect(core.endpoint.commands("subscribe")).toHaveLength(0)
  })

  it("a send from this device shows its attachment's bytes; a video's thumbnail waits for the server", () => {
    const { core, sources, show } = setup()
    const local = owner(0, { messageId: undefined, attachmentId: "a".repeat(24), clientKey: "5", state: "sending" })
    show(sources.photo(photo(), box, local))
    expect(core.mediaSubs()[0]!.ref).toEqual({ kind: "attachment", attachmentId: "a".repeat(24) })
    expect(sources.photo(photo(), box, local, true).state.peek()).toEqual({ status: "pending" })
    const video: VideoInfo = { id: "3" as FileID, width: 10, height: 10, duration: 1, size: 5, fileUniqueId: "V" }
    expect(sources.video(video, local)).toBe(sources.photo(photo(), box, local))
  })
})

describe("CoreMediaSources: uploads", () => {
  const local = owner(0, { messageId: undefined, attachmentId: "b".repeat(24), clientKey: "42", state: "sending" })

  it("progress, cancel and resend", () => {
    const { core, sources, defer } = setup()
    const upload = sources.upload(local)!
    upload.part!.attach(fakeElement("ring"))
    defer.flush()
    const sub = core.mediaSubs()[0]!.sub
    core.media(sub, { state: "ready", blob: blob(), upload: { state: "uploading", sentBytes: 512, totalBytes: 2048 } })
    expect(upload.state.peek()).toEqual({ phase: "uploading", fraction: 0.25 })
    core.media(sub, { state: "ready", blob: blob(), upload: { state: "failed", sentBytes: 512, totalBytes: 2048, retryable: true } })
    expect(upload.state.peek().phase).toBe("failed")
    upload.resend()
    upload.cancel()
    expect(core.intents().map(({ intent }) => intent)).toEqual([
      { kind: "retrySend", chatId: chat, clientKey: "42" },
      { kind: "deleteMessages", chatId: chat, messageIds: [], clientKeys: ["42"] },
    ])
  })

  it("hands cancel and resend to the app when it asks", () => {
    const core = scriptedCore()
    const calls: string[] = []
    const sources = createCoreMediaSources({
      client: core.client,
      urls: fakeBlobUrls(),
      clock: core.time,
      onCancelUpload: (o) => calls.push(`cancel ${o.clientKey}`),
      onResend: (o) => calls.push(`resend ${o.clientKey}`),
    })
    const upload = sources.upload(local)!
    upload.cancel()
    upload.resend()
    expect(calls).toEqual(["cancel 42", "resend 42"])
    expect(core.intents()).toEqual([])
    expect(sources.upload(owner(1))).toBeUndefined()
  })
})

describe("CoreMediaSources: visibility and hints", () => {
  const timeline = () => {
    const container = fakeElement("timeline")
    const rows = Array.from({ length: 6 }, (_, index) => fakeElement(`row ${index}`, container))
    return { container, rows }
  }

  it("inside a timeline, a held box subscribes only once it is visible; nearby ones go out as one hint per frame", () => {
    const { core, sources, frame, defer, observers } = setup()
    const { container, rows } = timeline()
    const visibility = sources.createVisibility()
    visibility.attach(container)
    const [visibleObserver, nearbyObserver] = observers.all
    expect(visibleObserver!.rootMargin).toBe("0px")
    expect(nearbyObserver!.rootMargin).toBe("100% 0px")

    const shown = rows.map((element, index) => {
      const source = sources.photo(photo(`F${index}`), box, owner(index + 1))
      source.part!.attach(element)
      return source
    })
    defer.flush()
    expect(core.mediaSubs()).toHaveLength(0)
    expect(visibleObserver!.observed.size).toBe(6)

    // Rows 2 and 3 on screen; 1 and 4 within a viewport.
    visibleObserver!.report([rows[2]!, rows[3]!].map((target) => ({ target, isIntersecting: true })))
    nearbyObserver!.report([1, 2, 3, 4].map((index) => ({ target: rows[index]!, isIntersecting: true })))
    expect(frame.size()).toBe(1)
    frame.flush()
    expect(core.mediaSubs().map((sub) => (sub.ref as { messageId: string }).messageId)).toEqual(["3", "4"])
    const hints = core.intents("mediaHints")
    expect(hints).toHaveLength(1)
    expect(hints[0]!.intent.nearby.map((ref) => (ref as { messageId: string }).messageId)).toEqual(["2", "5"])

    // The same sets again: no new hint.
    nearbyObserver!.report([{ target: rows[4]!, isIntersecting: true }])
    frame.flush()
    expect(core.intents("mediaHints")).toHaveLength(1)

    // Scroll: row 4 becomes visible, row 5 near. Row 3 stays subscribed (held).
    visibleObserver!.report([
      { target: rows[2]!, isIntersecting: false },
      { target: rows[4]!, isIntersecting: true },
    ])
    nearbyObserver!.report([
      { target: rows[1]!, isIntersecting: false },
      { target: rows[5]!, isIntersecting: true },
    ])
    frame.flush()
    expect(core.mediaSubs().map((sub) => (sub.ref as { messageId: string }).messageId)).toEqual(["3", "4", "5"])
    const last = core.intents("mediaHints").at(-1)!.intent.nearby
    expect(last.map((ref) => (ref as { messageId: string }).messageId)).toEqual(["6"])
    expect(core.intents("mediaHints")).toHaveLength(2)
    void shown
  })

  it("a released box leaves the hints; an empty set is sent once to clear them", () => {
    const { core, sources, frame, defer, observers } = setup()
    const { container, rows } = timeline()
    sources.createVisibility().attach(container)
    const source = sources.photo(photo(), box, owner(1))
    const release = source.part!.attach(rows[0]!)
    defer.flush()
    observers.all[1]!.report([{ target: rows[0]!, isIntersecting: true }])
    frame.flush()
    expect(core.intents("mediaHints").map(({ intent }) => intent.nearby.length)).toEqual([1])
    release()
    frame.flush()
    expect(core.intents("mediaHints").map(({ intent }) => intent.nearby.length)).toEqual([1, 0])
    frame.flush()
    expect(core.intents("mediaHints")).toHaveLength(2)
  })

  it("a box outside every timeline subscribes at once", () => {
    const { core, sources, defer } = setup()
    const { container } = timeline()
    sources.createVisibility().attach(container)
    sources.photo(photo(), box, owner(1)).part!.attach(fakeElement("elsewhere"))
    defer.flush()
    expect(core.mediaSubs()).toHaveLength(1)
  })

  it("never hints attachments, and de-duplicates refs shared by two boxes", () => {
    const { core, sources, frame, defer, observers } = setup()
    const { container, rows } = timeline()
    sources.createVisibility().attach(container)
    const shared = sources.photo(photo(), box, owner(1))
    shared.part!.attach(rows[0]!)
    shared.part!.attach(rows[1]!)
    const local = owner(0, { messageId: undefined, attachmentId: "c".repeat(24), clientKey: "1", state: "sending" })
    sources.photo(photo(), box, local).part!.attach(rows[2]!)
    defer.flush()
    observers.all[1]!.report(rows.slice(0, 3).map((target) => ({ target, isIntersecting: true })))
    frame.flush()
    const nearby: MediaRef[] = core.intents("mediaHints")[0]!.intent.nearby
    expect(nearby).toEqual([{ kind: "message", chatId: chat, messageId: "1", size: "f" }])
  })
})

describe("CoreMediaSources: a send completing", () => {
  const attachmentId = "d".repeat(24)
  const sending = owner(0, { messageId: undefined, attachmentId, clientKey: "77", state: "sending" })
  const sent = owner(500, { clientKey: "77", state: "sent" })

  it("keeps showing the local image until the server copy is ready: the URL never changes underneath the mounted image", () => {
    const { core, urls, sources, defer, state } = setup()
    // Sending: the box shows the attachment's bytes.
    const sendingSource = sources.photo(photo(), box, sending)
    const element = fakeElement("row 77")
    const releaseSending = sendingSource.part!.attach(element)
    defer.flush()
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: blob() })
    const localUrl = urls.created[0]!
    expect(state(sendingSource)).toEqual({ status: "ready", url: localUrl })

    // The send completes: the row now names the server's photo. The view swaps sources in one commit.
    const sentSource = sources.photo(photo(), box, sent)
    expect(sentSource).not.toBe(sendingSource)
    const seen: string[] = []
    const stop = effect(() => {
      const value = sentSource.state.get()
      seen.push(value.status === "ready" ? value.url : value.status)
    })
    const releaseSent = sentSource.part!.attach(element)
    releaseSending()
    defer.flush()
    expect(state(sentSource)).toEqual({ status: "ready", url: localUrl })
    // The server copy is asked for while the local one shows.
    const serverSub = core.mediaSubs((ref) => ref.kind === "message")[0]!
    expect(serverSub.ref).toEqual({ kind: "message", chatId: chat, messageId: "500", size: "f" })
    // A re-render keeps the same source.
    expect(sources.photo(photo(), box, sent)).toBe(sentSource)
    // The attachment's bytes move to the server file (the core releases the job): still the same URL on screen.
    const attachmentSub = core.mediaSubs((ref) => ref.kind === "attachment")[0]!
    core.media(attachmentSub.sub, { state: "absent" })
    core.media(serverSub.sub, { state: "downloading", receivedBytes: 5, totalBytes: 10 })
    expect(state(sentSource)).toEqual({ status: "ready", url: localUrl })
    // Ready: one switch, to the server's URL, never through pending.
    core.media(serverSub.sub, { state: "ready", blob: blob(20) })
    const serverUrl = urls.created[1]!
    expect(state(sentSource)).toEqual({ status: "ready", url: serverUrl })
    expect(seen).toEqual([localUrl, serverUrl])
    stop()

    // The row goes away: every URL is revoked after the grace period, nothing leaks.
    releaseSent()
    core.time.advance(MEDIA_GRACE_MS)
    expect(sources.stats()).toMatchObject({ urls: 0, subscribed: 0, held: 0 })
    expect(urls.live.size).toBe(0)
    expect(urls.strays).toEqual([])
    // Rendered again later: the server's own source.
    expect(sources.photo(photo(), box, sent)).not.toBe(sentSource)
  })

  it("a sent row first seen after its server copy is ready, or never sent from here, gets the server's source", () => {
    const { core, sources, show } = setup()
    const sendingSource = sources.photo(photo(), box, sending)
    const shown = show(sendingSource)
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: blob() })
    const server = sources.photo(photo(), box, owner(500))
    expect(sources.photo(photo(), box, owner(501, { clientKey: "other" }))).toBe(server)
    show(server)
    core.media(core.mediaSubs((ref) => ref.kind === "message")[0]!.sub, { state: "ready", blob: blob(20) })
    // Ready already: no stand-in.
    expect(sources.photo(photo(), box, sent)).toBe(server)
    shown.release()
  })

  it("rows released before the server answers leave nothing behind", () => {
    const { core, urls, sources, show } = setup()
    const sendingShown = show(sources.photo(photo(), box, sending))
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: blob() })
    const sentSource = sources.photo(photo(), box, sent)
    const sentShown = show(sentSource)
    sendingShown.release()
    sentShown.release()
    core.time.advance(MEDIA_GRACE_MS)
    expect(sources.stats()).toMatchObject({ entries: 0, urls: 0, subscribed: 0 })
    expect(urls.live.size).toBe(0)
  })
})
