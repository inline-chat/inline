/**
 * Which emitted files the service worker precaches. Pure: a list of emitted
 * files in, a manifest out, so it is tested without running a build.
 *
 * The rule: start at the shell HTML and follow references. A chunk refers to
 * its static and dynamic imports; any text file (HTML, JS, CSS, worker
 * bundles) refers to every other emitted file whose name appears in it. That
 * reaches the entry chunk, its CSS, lazy chunks, the core worker (Vite emits
 * it as an asset whose URL is a string in the chunk), the worker's own chunks
 * and the SQLite WASM, and leaves out lab pages and everything only they use.
 * Source maps, other HTML files and the service worker itself are never
 * included.
 */

import { createHash } from "node:crypto"
import type { PrecacheEntry } from "../src/sw/protocol"

export interface EmittedFile {
  readonly fileName: string
  /** Text for chunks and text assets, bytes for binary assets. */
  readonly content: string | Uint8Array
  readonly imports?: readonly string[]
  readonly dynamicImports?: readonly string[]
}

export interface PrecacheManifestOptions {
  /** Vite's resolved `base`, e.g. `/`. */
  readonly base: string
  /** The shell document's file name in the bundle. Default `index.html`. */
  readonly shellHtml?: string
  /** The service worker's own file name, never precached. Default `sw.js`. */
  readonly serviceWorkerFileName?: string
  /** More files to leave out, by emitted file name. */
  readonly exclude?: (fileName: string) => boolean
}

export interface PrecacheManifest {
  readonly shell: PrecacheEntry
  /** The shell's `<meta http-equiv="Content-Security-Policy">` value, decoded; absent when it has none. */
  readonly shellPolicy?: string
  readonly assets: readonly PrecacheEntry[]
  /** Emitted files not precached, for the build report. */
  readonly skipped: readonly string[]
}

const TEXT_EXTENSIONS = [".js", ".mjs", ".css", ".html", ".json", ".svg", ".webmanifest"]
const decoder = new TextDecoder()

/** First 16 hex characters of the SHA-256: the service worker checks the same on install. */
export const revisionOfContent = (content: string | Uint8Array): string =>
  createHash("sha256").update(content).digest("hex").slice(0, 16)

const sizeOf = (content: string | Uint8Array): number =>
  typeof content === "string" ? Buffer.byteLength(content) : content.byteLength

const textOf = (file: EmittedFile): string | null => {
  if (typeof file.content === "string") return file.content
  return TEXT_EXTENSIONS.some((extension) => file.fileName.endsWith(extension)) ? decoder.decode(file.content) : null
}

const entities: Readonly<Record<string, string>> = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", "#39": "'", "#34": '"' }
const decodeAttribute = (value: string): string =>
  value.replace(/&(amp|quot|apos|lt|gt|#39|#34);/g, (_match, name: string) => entities[name] ?? "")

const attributeOf = (tag: string, name: string): string | undefined => {
  const match = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag)
  if (!match) return undefined
  return decodeAttribute(match[1] ?? match[2] ?? match[3] ?? "")
}

/**
 * The content policy a shell's meta tag carries. Exactly one policy meta tag
 * is expected; with none it returns undefined, with several it throws, since
 * the worker could not repeat them faithfully as one header.
 */
export const shellPolicyOf = (html: string): string | undefined => {
  const policies: string[] = []
  for (const [tag] of html.matchAll(/<meta\b[^>]*>/gi)) {
    if (attributeOf(tag, "http-equiv")?.toLowerCase() !== "content-security-policy") continue
    const content = attributeOf(tag, "content")
    if (content !== undefined) policies.push(content.trim())
  }
  if (policies.length > 1) throw new Error("service worker: the shell has more than one content policy meta tag")
  return policies[0] || undefined
}

const baseName = (fileName: string): string => fileName.slice(fileName.lastIndexOf("/") + 1)

export const buildPrecacheManifest = (
  files: readonly EmittedFile[],
  options: PrecacheManifestOptions,
): PrecacheManifest => {
  const shellHtml = options.shellHtml ?? "index.html"
  const serviceWorkerFileName = options.serviceWorkerFileName ?? "sw.js"
  const base = options.base.endsWith("/") ? options.base : `${options.base}/`

  const shell = files.find((file) => file.fileName === shellHtml)
  if (!shell) throw new Error(`service worker: the shell ${shellHtml} is not in the bundle`)

  const neverPrecached = (fileName: string): boolean =>
    fileName.endsWith(".map") ||
    fileName.endsWith(".html") ||
    fileName === serviceWorkerFileName ||
    fileName.startsWith(".vite/") ||
    options.exclude?.(fileName) === true

  const candidates = new Map(
    files.filter((file) => !neverPrecached(file.fileName)).map((file) => [file.fileName, file] as const),
  )

  const reached = new Set<string>()
  const queue: EmittedFile[] = [shell]
  while (queue.length > 0) {
    const file = queue.shift()
    if (!file) break
    const text = textOf(file)
    const references = new Set([...(file.imports ?? []), ...(file.dynamicImports ?? [])])
    if (text !== null) {
      for (const name of candidates.keys()) if (text.includes(baseName(name))) references.add(name)
    }
    for (const name of references) {
      const next = candidates.get(name)
      if (!next || reached.has(name) || name === file.fileName) continue
      reached.add(name)
      queue.push(next)
    }
  }

  const entry = (file: EmittedFile, url: string): PrecacheEntry => ({
    url,
    revision: revisionOfContent(file.content),
    size: sizeOf(file.content),
  })

  const shellText = textOf(shell)
  const shellPolicy = shellText === null ? undefined : shellPolicyOf(shellText)
  return {
    shell: entry(shell, base),
    ...(shellPolicy !== undefined ? { shellPolicy } : {}),
    assets: Array.from(reached)
      .sort()
      .map((name) => {
        const file = candidates.get(name)
        if (!file) throw new Error(`service worker: lost ${name}`)
        return entry(file, `${base}${name}`)
      }),
    skipped: files
      .map((file) => file.fileName)
      .filter((name) => name !== shellHtml && !reached.has(name))
      .sort(),
  }
}
