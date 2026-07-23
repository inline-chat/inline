import { userId } from "@inline/ids"
import { flushSync } from "react-dom"
import { createRoot } from "react-dom/client"
import { MessageContentView } from "../../chat/MessageContentView"
import { InlineMediaProvider } from "../../inline/media/InlineMediaContext"
import { promoteInlineFirstFrameMedia } from "../../inline/media/InlineFirstFrameMedia"
import { InlineMediaLoader } from "../../inline/media/InlineMediaLoader"
import { InlineMediaRepository } from "../../inline/media/InlineMediaRepository"
import { inlineTinyThumbnailDataUrl } from "../../inline/media/InlineTinyThumbnail"
import { OpfsInlineMediaCache } from "../../inline/media/cache/OpfsInlineMediaCache"
import { IndexedDbInlineMediaCache } from "../../inline/media/cache/IndexedDbInlineMediaCache"
import { createInlineMediaCache } from "../../inline/media/cache/createInlineMediaCache"

const stateKey = "inline-media-persistence-browser-harness-v1"
const accountId = userId(91_777_001)
const fallbackAccountId = userId(91_777_002)
const opfsLruAccountId = userId(91_777_003)
const indexedDbLruAccountId = userId(91_777_004)
const firstUrl =
  "https://api.inline.chat/file?id=persistent-photo&exp=1&sig=first"
const rotatedUrl =
  "https://api.inline.chat/file?id=persistent-photo&exp=2&sig=rotated"
const pngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
// Shared with InlineTinyThumbnailDecoderTests: a real 40 x 25 protocol
// stripped JPEG, not a browser-ready thumbnail fabricated by the harness.
const strippedThumbnailBase64 =
  "ARkoAAwDAQACEQMRAD8AqUUUV0mAUUUUAFFFFABRRRQAUUUUAFFFFAE="

type PersistedHarnessState = {
  key: string
  fallbackKey: string
  expectedBase64: string
}

type StorageManagerWithOptionalOpfs = StorageManager & {
  getDirectory?: () => Promise<FileSystemDirectoryHandle>
}

const decodeBase64 = (value: string) => {
  const binary = atob(value)
  return Uint8Array.from(
    binary,
    (character) => character.charCodeAt(0),
  )
}

const encodeBase64 = (value: ArrayBuffer) => {
  const bytes = new Uint8Array(value)
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

const readState = () => {
  const value = sessionStorage.getItem(stateKey)
  if (!value) throw new Error("Persistent media seed state is missing")
  return JSON.parse(value) as PersistedHarnessState
}

const withOpfsUnavailable = async <T,>(operation: () => Promise<T>) => {
  const storage = navigator.storage as StorageManagerWithOptionalOpfs
  const ownDescriptor = Object.getOwnPropertyDescriptor(
    storage,
    "getDirectory",
  )
  Object.defineProperty(storage, "getDirectory", {
    configurable: true,
    value: undefined,
  })
  try {
    return await operation()
  } finally {
    if (ownDescriptor) {
      Object.defineProperty(storage, "getDirectory", ownDescriptor)
    } else {
      Reflect.deleteProperty(storage, "getDirectory")
    }
  }
}

const pngBlob = () =>
  new Blob([decodeBase64(pngBase64)], {
    type: "image/png",
  })

const seed = async () => {
  const key = `photo:persistence:${crypto.randomUUID()}:d`
  const fallbackKey = `photo:indexeddb:${crypto.randomUUID()}:d`
  let byteLoads = 0
  const cache = new OpfsInlineMediaCache({ accountId })
  const loader = new InlineMediaLoader({
    cache,
    fetcher: async () => {
      byteLoads += 1
      return new Response(pngBlob(), { status: 200 })
    },
  })
  const loaded = await loader.load(key, firstUrl)
  if (loaded.kind !== "blob") {
    throw new Error("Initial media seed did not produce owned bytes")
  }
  let fallbackByteLoads = 0
  const fallbackLoaded = await withOpfsUnavailable(async () => {
    const fallbackLoader = new InlineMediaLoader({
      cache: createInlineMediaCache({
        accountId: fallbackAccountId,
      }),
      fetcher: async () => {
        fallbackByteLoads += 1
        return new Response(pngBlob(), { status: 200 })
      },
    })
    return await fallbackLoader.load(fallbackKey, firstUrl)
  })
  if (fallbackLoaded.kind !== "blob") {
    throw new Error("IndexedDB fallback seed did not produce owned bytes")
  }
  sessionStorage.setItem(
    stateKey,
    JSON.stringify({
      key,
      fallbackKey,
      expectedBase64: pngBase64,
    }),
  )
  return {
    key,
    byteLoads,
    fallbackKey,
    fallbackByteLoads,
    byteLength: loaded.blob.size,
    fallbackByteLength: fallbackLoaded.blob.size,
    resourceKind: loaded.kind,
    fallbackResourceKind: fallbackLoaded.kind,
    opfsAvailable:
      typeof navigator.storage.getDirectory === "function",
  }
}

const testBoundedLru = async (runId: string) => {
  let opfsNow = 1
  const opfs = new OpfsInlineMediaCache({
    accountId: opfsLruAccountId,
    maxBytes: 8,
    now: () => opfsNow++,
  })
  const opfsFirst = `opfs-lru:${runId}:first`
  const opfsSecond = `opfs-lru:${runId}:second`
  const opfsThird = `opfs-lru:${runId}:third`
  await opfs.put(opfsFirst, new Blob(["12"]))
  await opfs.put(opfsSecond, new Blob(["34"]))
  await opfs.get(opfsFirst)
  await opfs.put(opfsThird, new Blob(["567890"]))

  const indexedDb = new IndexedDbInlineMediaCache({
    accountId: indexedDbLruAccountId,
    maxBytes: 8,
  })
  const indexedDbFirst = `idb-lru:${runId}:first`
  const indexedDbSecond = `idb-lru:${runId}:second`
  const indexedDbThird = `idb-lru:${runId}:third`
  await indexedDb.put(indexedDbFirst, new Blob(["12"]))
  await new Promise((resolve) => setTimeout(resolve, 4))
  await indexedDb.put(indexedDbSecond, new Blob(["34"]))
  await new Promise((resolve) => setTimeout(resolve, 4))
  await indexedDb.get(indexedDbFirst)
  await new Promise((resolve) => setTimeout(resolve, 4))
  await indexedDb.put(indexedDbThird, new Blob(["567890"]))

  return {
    opfs: {
      first: Boolean(await opfs.get(opfsFirst)),
      second: Boolean(await opfs.get(opfsSecond)),
      third: Boolean(await opfs.get(opfsThird)),
    },
    indexedDb: {
      first: Boolean(await indexedDb.get(indexedDbFirst)),
      second: Boolean(await indexedDb.get(indexedDbSecond)),
      third: Boolean(await indexedDb.get(indexedDbThird)),
    },
  }
}

let retainedRoot: ReturnType<typeof createRoot> | undefined
let releaseColdPhotoBytes: (() => void) | undefined
let coldPhotoByteLoads = 0

const renderColdPhoto = () => {
  const root = document.querySelector<HTMLElement>(
    "#media-persistence-harness-root",
  )
  if (!root) throw new Error("Persistent media harness root is missing")

  retainedRoot?.unmount()
  releaseColdPhotoBytes = undefined
  coldPhotoByteLoads = 0
  const repository = new InlineMediaRepository({
    loadCached: async () => undefined,
    load: async () => {
      coldPhotoByteLoads += 1
      await new Promise<void>((resolve) => {
        releaseColdPhotoBytes = resolve
      })
      return { kind: "blob", blob: pngBlob() }
    },
  })
  const tinyThumbnailUrl = inlineTinyThumbnailDataUrl(
    decodeBase64(strippedThumbnailBase64),
  )
  if (!tinyThumbnailUrl) {
    throw new Error("Real stripped thumbnail fixture did not decode")
  }

  retainedRoot = createRoot(root)
  flushSync(() => {
    retainedRoot?.render(
      <InlineMediaProvider repository={repository}>
        <MessageContentView
          presentation={{
            media: {
              kind: "photo",
              mediaKey: "photo:cold-first-frame:d",
              remoteUrl:
                "https://api.inline.chat/file?id=cold-first-frame",
              tinyThumbnailUrl,
              width: 800,
              height: 600,
              label: "Photo",
            },
          }}
        />
      </InlineMediaProvider>,
    )
  })

  return {
    tinyThumbnailUrl,
    byteLoads: coldPhotoByteLoads,
  }
}

const releaseColdPhoto = () => {
  if (!releaseColdPhotoBytes) {
    throw new Error("Cold photo byte acquisition has not started")
  }
  releaseColdPhotoBytes()
  releaseColdPhotoBytes = undefined
  return { byteLoads: coldPhotoByteLoads }
}

const reopenOffline = async () => {
  const state = readState()
  performance.clearResourceTimings()

  // Recreate the complete cache/loader owner after the document reload. A
  // cache miss would attempt the rotated API capability and fail while Chrome
  // is offline; a hit returns OPFS bytes before touching fetch.
  const reopenedLoader = new InlineMediaLoader({
    cache: new OpfsInlineMediaCache({ accountId }),
  })
  const reopened = await reopenedLoader.load(
    state.key,
    rotatedUrl,
  )
  if (reopened.kind !== "blob") {
    throw new Error("Offline owner recreation missed persistent media")
  }

  // Route preparation owns a separate cache-only read. Recreate the owner
  // again to prove the renderer is populated from persistence, not from the
  // previous loader's resident result.
  const promotionLoader = new InlineMediaLoader({
    cache: new OpfsInlineMediaCache({ accountId }),
  })
  const repository = new InlineMediaRepository(promotionLoader)
  const promoted = await promoteInlineFirstFrameMedia(repository, [
    { key: state.key },
    { key: state.key },
  ])
  const blobUrl = repository.peek(state.key, rotatedUrl)
  if (promoted !== 1 || !blobUrl?.startsWith("blob:")) {
    throw new Error("Cache-only route promotion did not prepare one Blob")
  }
  const promotedBytes = await fetch(blobUrl).then((response) =>
    response.arrayBuffer(),
  )
  if (encodeBase64(promotedBytes) !== state.expectedBase64) {
    throw new Error("Promoted OPFS bytes changed across owner recreation")
  }

  const fallbackResult = await withOpfsUnavailable(async () => {
    const fallbackLoader = new InlineMediaLoader({
      cache: createInlineMediaCache({
        accountId: fallbackAccountId,
      }),
    })
    const loaded = await fallbackLoader.load(
      state.fallbackKey,
      rotatedUrl,
    )
    const repository = new InlineMediaRepository(
      new InlineMediaLoader({
        cache: createInlineMediaCache({
          accountId: fallbackAccountId,
        }),
      }),
    )
    const promoted = await promoteInlineFirstFrameMedia(repository, [
      { key: state.fallbackKey },
    ])
    const url = repository.peek(state.fallbackKey, rotatedUrl)
    const bytes = url
      ? await fetch(url).then((response) => response.arrayBuffer())
      : undefined
    return {
      kind: loaded.kind,
      promoted,
      bytesMatch:
        bytes != null && encodeBase64(bytes) === state.expectedBase64,
    }
  })

  const storage = navigator.storage as StorageManager & {
    getDirectory(): Promise<FileSystemDirectoryHandle>
  }
  const rootDirectory = await storage.getDirectory()
  const mediaDirectory = await rootDirectory.getDirectoryHandle(
    "inline-media",
  )
  let fallbackOpfsDirectoryExists = true
  try {
    await mediaDirectory.getDirectoryHandle(
      `account-${fallbackAccountId}`,
    )
  } catch (error) {
    if (error instanceof DOMException && error.name === "NotFoundError") {
      fallbackOpfsDirectoryExists = false
    } else {
      throw error
    }
  }
  const boundedLru = await testBoundedLru(state.key)

  const root = document.querySelector<HTMLElement>(
    "#media-persistence-harness-root",
  )
  if (!root) throw new Error("Persistent media harness root is missing")
  retainedRoot?.unmount()
  retainedRoot = createRoot(root)
  flushSync(() => {
    retainedRoot?.render(
      <InlineMediaProvider repository={repository}>
        <MessageContentView
          presentation={{
            media: {
              kind: "photo",
              mediaKey: state.key,
              remoteUrl: rotatedUrl,
              tinyThumbnailUrl: "data:image/jpeg;base64,/9j/2Q==",
              width: 800,
              height: 600,
              label: "Photo",
            },
          }}
        />
      </InlineMediaProvider>,
    )
  })
  const image = root.querySelector<HTMLImageElement>('img[alt="Photo"]')
  const frame = image?.parentElement
  const resourceEntries = performance
    .getEntriesByType("resource")
    .filter((entry) => entry.name === rotatedUrl)
  return {
    resourceKind: reopened.kind,
    promoted,
    blobUrl,
    firstCommitSource: image?.getAttribute("src"),
    frameWidth: frame?.style.width,
    frameHeight: frame?.style.height,
    rotatedUrlResourceRequests: resourceEntries.length,
    online: navigator.onLine,
    fallback: fallbackResult,
    fallbackOpfsDirectoryExists,
    boundedLru,
  }
}

declare global {
  interface Window {
    inlineMediaPersistenceHarness: {
      seed: typeof seed
      reopenOffline: typeof reopenOffline
      renderColdPhoto: typeof renderColdPhoto
      releaseColdPhoto: typeof releaseColdPhoto
    }
    inlineMediaPersistenceHarnessReady: boolean
    inlineMediaPersistenceHarnessErrors: string[]
  }
}

window.inlineMediaPersistenceHarnessErrors = []
window.addEventListener("error", (event) => {
  window.inlineMediaPersistenceHarnessErrors.push(
    event.error?.stack ?? event.message ?? "unknown browser error",
  )
})
window.addEventListener("unhandledrejection", (event) => {
  window.inlineMediaPersistenceHarnessErrors.push(
    event.reason?.stack ?? String(event.reason),
  )
})
window.inlineMediaPersistenceHarness = {
  seed,
  reopenOffline,
  renderColdPhoto,
  releaseColdPhoto,
}
window.inlineMediaPersistenceHarnessReady = true
