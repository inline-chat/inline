/**
 * The emoji services an app creates once: usage on this device, the lazily
 * loaded engine (the data chunk) and the drawability check. Small: it
 * imports the engine only through `import()`, so the table never reaches
 * the bundle that imports this.
 */

import { signal, type ReadSignal } from "@inline/reactive"
import type { EmojiEngine } from "./engine"
import { canvasEmojiProbe, createEmojiSupport, type EmojiSupport } from "./support"
import { EmojiUsage, localStorageKeyValueStore, type KeyValueStore } from "./usage"

export type EmojiLoadStatus = "idle" | "loading" | "ready" | "error"

export type EmojiEngineLoader = {
  /** The engine once loaded; undefined before. Read it in a computed and the list fills in when it arrives. */
  readonly engine: ReadSignal<EmojiEngine | undefined>
  readonly status: ReadSignal<EmojiLoadStatus>
  /** Start loading (once; again after a failure). Resolves with the engine. */
  load(): Promise<EmojiEngine>
}

/** The emoji chunk: the engine and the generated table. */
export const importEmojiEngine = async (): Promise<EmojiEngine> => {
  const module = await import("./engine")
  return module.createEmojiEngine()
}

export const createEmojiEngineLoader = (importer: () => Promise<EmojiEngine> = importEmojiEngine): EmojiEngineLoader => {
  const engine = signal<EmojiEngine | undefined>(undefined)
  const status = signal<EmojiLoadStatus>("idle")
  let pending: Promise<EmojiEngine> | undefined
  return {
    engine,
    status,
    load: () => {
      const loaded = engine.peek()
      if (loaded) return Promise.resolve(loaded)
      if (pending) return pending
      status.set("loading")
      pending = importer().then(
        (value) => {
          engine.set(value)
          status.set("ready")
          return value
        },
        (error: unknown) => {
          pending = undefined
          status.set("error")
          throw error
        },
      )
      return pending
    },
  }
}

export type EmojiServices = {
  readonly usage: EmojiUsage
  readonly loader: EmojiEngineLoader
  readonly support: EmojiSupport
  /** Load the engine and check which emoji draw, on the idle lane. For the app's warm-up after first paint. */
  warm(): Promise<EmojiEngine>
}

export type EmojiServicesOptions = {
  /** Where usage lives. Default `localStorage`, guarded. */
  readonly store?: KeyValueStore
  readonly now?: () => number
  readonly importEngine?: () => Promise<EmojiEngine>
  readonly support?: EmojiSupport
}

export const createEmojiServices = (options: EmojiServicesOptions = {}): EmojiServices => {
  const loader = createEmojiEngineLoader(options.importEngine)
  const support = options.support ?? createEmojiSupport({ probe: () => canvasEmojiProbe() })
  let scanned = false
  const usage = new EmojiUsage({ store: options.store ?? localStorageKeyValueStore(), ...(options.now ? { now: options.now } : {}) })
  return {
    usage,
    loader,
    support,
    warm: async () => {
      const engine = await loader.load()
      if (!scanned) {
        scanned = true
        support.scan(engine.all.map((item) => item.emoji))
      }
      return engine
    },
  }
}
