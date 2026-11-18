import type { PhotoInfo, VideoInfo } from "@inline/core-protocol"
import type { FileID, PhotoID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { GifPlaybackController, type Condition, type PlaybackVideo } from "./gif-playback"
import { type ObjectUrlApi, PreviewUrls, type PreviewTarget } from "./preview-urls"
import { LoadedMedia, RevealController, type RevealImage, type RevealStatus } from "./reveal"
import { cdnMediaSources, mediaUrl } from "./sources"

// ---------------------------------------------------------------------------
// Fakes

const fakeUrls = () => {
  let next = 0
  const live = new Set<string>()
  const revoked: string[] = []
  const api: ObjectUrlApi = {
    create: () => {
      const url = `blob:test/${++next}`
      live.add(url)
      return url
    },
    revoke: (url) => {
      live.delete(url)
      revoked.push(url)
    },
  }
  return { api, live, revoked }
}

const manualDefer = () => {
  const queue: (() => void)[] = []
  return {
    defer: (fn: () => void) => void queue.push(fn),
    flush: () => {
      while (queue.length > 0) queue.shift()?.()
    },
  }
}

const fakeTarget = () => {
  const props = new Map<string, string>()
  const target: PreviewTarget = {
    style: {
      setProperty: (name: string, value: string | null) => void props.set(name, value ?? ""),
      removeProperty: (name: string) => {
        const value = props.get(name) ?? ""
        props.delete(name)
        return value
      },
    },
  }
  return { target, props }
}

type Deferred = { resolve: () => void; reject: () => void }

class FakeImage implements RevealImage {
  complete = false
  naturalWidth = 0
  srcSets = 0
  readonly decodes: Deferred[] = []
  #src = ""
  get src(): string {
    return this.#src
  }
  set src(value: string) {
    this.#src = value
    this.srcSets += 1
  }
  decode(): Promise<void> {
    return new Promise<void>((resolve, reject) => this.decodes.push({ resolve, reject: () => reject(new Error("decode")) }))
  }
  removeAttribute(name: string): void {
    if (name === "src") this.#src = ""
  }
}

const fakeImage = () => {
  const image = new FakeImage()
  return { image, decodes: image.decodes }
}

class FakeVideo extends EventTarget {
  src = ""
  loads = 0
  load(): void {
    this.loads += 1
  }
  removeAttribute(name: string): void {
    if (name === "src") this.src = ""
  }
  override addEventListener(type: string, listener: () => void): void {
    super.addEventListener(type, listener)
  }
  override removeEventListener(type: string, listener: () => void): void {
    super.removeEventListener(type, listener)
  }
}

/** Let settled promises run their callbacks (no timers). */
const tick = async () => {
  for (let index = 0; index < 5; index += 1) await Promise.resolve()
}

// ---------------------------------------------------------------------------

describe("PreviewUrls", () => {
  it("creates one URL per bytes object, paints it, and revokes after the last element lets go", () => {
    const urls = fakeUrls()
    const deferred = manualDefer()
    const previews = new PreviewUrls({ api: urls.api, defer: deferred.defer })
    const bytes = new Uint8Array([1, 2, 3])
    const a = fakeTarget()
    const b = fakeTarget()
    const part = previews.part(bytes)
    expect(previews.part(bytes)).toBe(part)
    const detachA = part.attach(a.target)
    const detachB = part.attach(b.target)
    expect(urls.live.size).toBe(1)
    expect(a.props.get("background-image")).toBe('url("blob:test/1")')
    expect(b.props.get("background-image")).toBe('url("blob:test/1")')
    detachA()
    deferred.flush()
    expect(urls.revoked).toEqual([])
    detachB()
    expect(b.props.has("background-image")).toBe(false)
    expect(urls.revoked).toEqual([])
    deferred.flush()
    expect(urls.revoked).toEqual(["blob:test/1"])
    expect(previews.size).toBe(0)
  })

  it("keeps the URL across a detach and attach in the same task", () => {
    const urls = fakeUrls()
    const deferred = manualDefer()
    const previews = new PreviewUrls({ api: urls.api, defer: deferred.defer })
    const bytes = new Uint8Array([9])
    const el = fakeTarget()
    const detach = previews.part(bytes).attach(el.target)
    detach()
    previews.part(bytes).attach(el.target)
    deferred.flush()
    expect(urls.revoked).toEqual([])
    expect(el.props.get("background-image")).toBe('url("blob:test/1")')
  })

  it("does nothing without bytes and revokes everything on dispose", () => {
    const urls = fakeUrls()
    const previews = new PreviewUrls({ api: urls.api, defer: () => {} })
    const el = fakeTarget()
    previews.part(undefined).attach(el.target)
    expect(el.props.size).toBe(0)
    previews.part(new Uint8Array([1])).attach(el.target)
    previews.part(new Uint8Array([2])).attach(el.target)
    previews.dispose()
    expect(urls.live.size).toBe(0)
    expect(previews.part(new Uint8Array([3])).attach(el.target)).toBeTypeOf("function")
    expect(urls.live.size).toBe(0)
  })
})

describe("LoadedMedia", () => {
  it("drops the oldest URL past its limit and refreshes on add", () => {
    const loaded = new LoadedMedia(2)
    loaded.add("a")
    loaded.add("b")
    loaded.add("a")
    loaded.add("c")
    expect(loaded.has("a")).toBe(true)
    expect(loaded.has("b")).toBe(false)
    expect(loaded.has("c")).toBe(true)
    expect(loaded.size).toBe(2)
  })
})

describe("RevealController", () => {
  it("is idle without a URL and never touches the element", () => {
    const controller = new RevealController({ url: undefined })
    const { image } = fakeImage()
    controller.part.attach(image)
    expect(controller.status.peek()).toBe("idle")
    expect(image.srcSets).toBe(0)
  })

  it("sets the source on attach and reveals only after decode", async () => {
    const loaded = new LoadedMedia()
    const statuses: RevealStatus[] = []
    const controller = new RevealController({ url: "https://m/1.jpg", loaded, onStatus: (s) => statuses.push(s) })
    expect(controller.status.peek()).toBe("loading")
    expect(controller.instant).toBe(false)
    const { image, decodes } = fakeImage()
    controller.part.attach(image)
    expect(image.src).toBe("https://m/1.jpg")
    expect(controller.status.peek()).toBe("loading")
    decodes[0]?.resolve()
    await tick()
    expect(controller.status.peek()).toBe("loaded")
    expect(statuses).toEqual(["loaded"])
    expect(loaded.has("https://m/1.jpg")).toBe(true)
    // Seen before: the next controller for the URL starts revealed.
    const again = new RevealController({ url: "https://m/1.jpg", loaded })
    expect(again.instant).toBe(true)
    expect(again.status.peek()).toBe("loaded")
  })

  it("fails on a decode error unless the element did load, and retries in place", async () => {
    const controller = new RevealController({ url: "https://m/2.jpg" })
    const { image, decodes } = fakeImage()
    controller.part.attach(image)
    decodes[0]?.reject()
    await tick()
    expect(controller.status.peek()).toBe("failed")
    controller.retry()
    expect(controller.status.peek()).toBe("loading")
    expect(image.srcSets).toBe(2)
    image.complete = true
    image.naturalWidth = 100
    decodes[1]?.reject()
    await tick()
    expect(controller.status.peek()).toBe("loaded")
  })

  it("ignores a decode that settles after detach or dispose", async () => {
    const controller = new RevealController({ url: "https://m/3.jpg" })
    const { image, decodes } = fakeImage()
    const detach = controller.part.attach(image)
    detach()
    decodes[0]?.resolve()
    await tick()
    expect(controller.status.peek()).toBe("loading")
    controller.part.attach(image)
    controller.dispose()
    decodes[1]?.resolve()
    await tick()
    expect(controller.status.peek()).toBe("loading")
  })

  it("reveals a GIF's video on its first frame and fails on error", () => {
    const controller = new RevealController({ url: "https://m/a.mp4", kind: "video" })
    const video = new FakeVideo()
    const detach = controller.part.attach(video)
    expect(video.src).toBe("https://m/a.mp4")
    video.dispatchEvent(new Event("error"))
    expect(controller.status.peek()).toBe("failed")
    controller.retry()
    expect(controller.status.peek()).toBe("loading")
    video.dispatchEvent(new Event("loadeddata"))
    expect(controller.status.peek()).toBe("loaded")
    detach()
    video.dispatchEvent(new Event("error"))
    expect(controller.status.peek()).toBe("loaded")
  })
})

describe("GifPlaybackController", () => {
  const condition = (value: boolean) => {
    let current = value
    const listeners = new Set<() => void>()
    const c: Condition & { set(v: boolean): void } = {
      get: () => current,
      subscribe: (listener) => {
        listeners.add(listener)
        return () => listeners.delete(listener)
      },
      set: (v) => {
        current = v
        for (const listener of listeners) listener()
      },
    }
    return c
  }

  const fakePlaybackVideo = () => {
    const video: PlaybackVideo & { plays: number; pauses: number } = {
      muted: false,
      loop: false,
      playsInline: false,
      paused: true,
      plays: 0,
      pauses: 0,
      play() {
        ;(this as { paused: boolean }).paused = false
        this.plays += 1
        return Promise.resolve()
      },
      pause() {
        ;(this as { paused: boolean }).paused = true
        this.pauses += 1
      },
    }
    return video
  }

  it("plays muted and looping only while visible, the page is shown and motion is allowed", () => {
    let setVisible: (visible: boolean) => void = () => {}
    const page = condition(true)
    const motion = condition(false)
    const controller = new GifPlaybackController({
      observeVisibility: (_el, listener) => {
        setVisible = listener
        return () => {}
      },
      pageVisible: page,
      reducedMotion: motion,
    })
    const video = fakePlaybackVideo()
    const detach = controller.part.attach(video)
    expect(video.muted && video.loop && video.playsInline).toBe(true)
    expect(video.paused).toBe(true)
    setVisible(true)
    expect(video.paused).toBe(false)
    page.set(false)
    expect(video.paused).toBe(true)
    page.set(true)
    expect(video.paused).toBe(false)
    motion.set(true)
    expect(video.paused).toBe(true)
    expect(controller.animate).toBe(false)
    motion.set(false)
    setVisible(false)
    expect(video.paused).toBe(true)
    setVisible(true)
    detach()
    expect(video.paused).toBe(true)
    setVisible(true)
    expect(video.paused).toBe(true)
  })
})

describe("cdnMediaSources", () => {
  const photo: PhotoInfo = {
    id: "1" as PhotoID,
    sizes: [
      { type: "b", width: 140, height: 100, cdnUrl: "https://cdn.example/b.jpg" },
      { type: "d", width: 800, height: 571, cdnUrl: "https://cdn.example/d.jpg" },
      { type: "f", width: 2000, height: 1428, cdnUrl: "javascript:alert(1)" },
    ],
  }

  it("picks the smallest covering size, caches per input, and refuses unsafe URLs", () => {
    const sources = cdnMediaSources({ pixelRatio: () => 2 })
    const small = sources.photo(photo, { width: 60, height: 43 })
    expect(small.state.peek()).toEqual({ status: "ready", url: "https://cdn.example/b.jpg" })
    expect(sources.photo(photo, { width: 60, height: 43 })).toBe(small)
    expect(sources.photo(photo, { width: 320, height: 228 }).state.peek()).toEqual({
      status: "ready",
      url: "https://cdn.example/d.jpg",
    })
    // Larger than every safe size: the best size is the unsafe one, so nothing loads.
    expect(sources.photo(photo, { width: 1200, height: 857 }).state.peek()).toEqual({ status: "failed" })
    const video: VideoInfo = { id: "2" as FileID, width: 1, height: 1, duration: 1, size: 1, cdnUrl: "data:video/mp4,x" }
    expect(sources.video(video).state.peek()).toEqual({ status: "failed" })
  })

  it("accepts web links only", () => {
    expect(mediaUrl("https://x.example/a.png")).toBe("https://x.example/a.png")
    expect(mediaUrl("blob:https://x.example/1")).toBeUndefined()
    expect(mediaUrl(undefined)).toBeUndefined()
  })
})
