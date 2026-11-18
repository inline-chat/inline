import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { dirname, join, normalize } from "node:path"
import { fileURLToPath } from "node:url"
import { queueShellWarmup, shellWarmers, shellWarmOrder, type ShellWarmers } from "./shell-warmup"
import { afterFirstPaint, bootWarmed, chunkImporters } from "./view-chunks"

const here = dirname(fileURLToPath(import.meta.url))
const web = normalize(join(here, "../.."))

/** The `import("...")` specifier a module's loader uses, resolved to a file under `web/`. */
const holderTarget = (file: string, pattern: RegExp): string => {
  const source = readFileSync(join(web, file), "utf8")
  const specifier = pattern.exec(source)?.[1]
  if (!specifier) throw new Error(`no import in ${file}`)
  return normalize(join(dirname(file), specifier))
}

/** `chunkImporters[name]`'s specifier, resolved like the measurement does (`@inline/x/y` through the package's exports). */
const tableTarget = (name: keyof typeof chunkImporters): string => {
  const source = readFileSync(join(here, "view-chunks.ts"), "utf8")
  const specifier = new RegExp(`^\\s*${name}:\\s*\\(\\)\\s*=>\\s*import\\("([^"]+)"\\)`, "m").exec(source)?.[1]
  if (!specifier) throw new Error(`no importer for ${name}`)
  if (specifier.startsWith(".")) return normalize(join("src/app", specifier))
  const [, pkg, sub] = /^@inline\/([^/]+)(?:\/(.+))?$/.exec(specifier) ?? []
  const exports = (JSON.parse(readFileSync(join(web, "packages", pkg!, "package.json"), "utf8")) as { exports: Record<string, { default: string }> })
    .exports
  const target = exports[sub ? `./${sub}` : "."]!.default
  return normalize(join("packages", pkg!, target))
}

const strip = (path: string) => path.replace(/\.(tsx?|js)$/, "")

describe("the shell's warm-up after its first paint", () => {
  it("covers every after-paint name boot does not queue, in the table's order", () => {
    const expected = afterFirstPaint.filter((name) => name !== "content" && !(bootWarmed as readonly string[]).includes(name))
    expect(shellWarmOrder).toEqual(expected)
    // Every name has a warmer (the type says so too), and nothing else is warmed but `content` and the emoji table.
    const warmers = shellWarmers({ content: () => {}, layers: () => {}, quickSearch: () => {}, settings: () => {} })
    expect(Object.keys(warmers).sort()).toEqual([...shellWarmOrder, "content", "emojiData"].sort())
  })

  it("loads content after the paint, then each name on the idle lane in order, the emoji table last, then marks the paint", async () => {
    const calls: string[] = []
    const tasks: (() => void | Promise<unknown>)[] = []
    let painted = false
    let afterPaint: (() => void) | undefined
    const warmers = Object.fromEntries(
      [...shellWarmOrder, "content", "emojiData"].map((name) => [name, () => void calls.push(name)]),
    ) as unknown as ShellWarmers
    queueShellWarmup({
      afterPaint: (fn) => {
        afterPaint = fn
      },
      warmup: {
        add: (task) => void tasks.push(task),
        painted: () => {
          painted = true
        },
      },
      warmers,
    })
    expect(painted).toBe(true)
    expect(calls).toEqual([])
    afterPaint?.()
    expect(calls).toEqual(["content"])
    for (const task of tasks) await task()
    expect(calls).toEqual(["content", ...shellWarmOrder, "emojiData"])
    expect(shellWarmOrder.indexOf("menus")).toBeLessThan(shellWarmOrder.indexOf("quickSearch"))
  })

  it("warms the feature holders the first use reads, which name the same module as the chunk table", () => {
    // The menu kit: `menuKit` (every lazy context menu) and `menus`.
    expect(strip(holderTarget("packages/ui/src/context-menu/kit.ts", /new Lazy\(\(\) => import\("([^"]+)"\)\)/))).toBe(
      strip(tableTarget("menus")),
    )
    // The composer's autocomplete chunk: `loadAutocompleteChunk` and `composerAutocomplete`.
    expect(strip(holderTarget("src/features/composer/autocomplete.ts", /import\("(\.\/autocomplete-chunk)"\)/))).toBe(
      strip(tableTarget("composerAutocomplete")),
    )
    // The paste module: `loadPasteModule` and `composerPaste`.
    expect(strip(holderTarget("packages/composer/src/clipboard.ts", /import\("(\.\/paste)"\)/))).toBe(strip(tableTarget("composerPaste")))
    // The attachment strip: `attachmentStripChunk` (loaded with the attachments chunk) and `attachmentStrip`.
    expect(strip(holderTarget("src/features/composer/strip-chunk.ts", /import\("(\.\/AttachmentStripView)"\)/))).toBe(
      strip(tableTarget("attachmentStrip")),
    )
  })
})
