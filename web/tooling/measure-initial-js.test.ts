import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import {
  checkEntries,
  chunkSpecifiers,
  directoryFiles,
  dynamicImports,
  gzipSize,
  htmlEntries,
  manifestKeyFor,
  measure,
  moduleShares,
  packageOf,
  packageRollup,
  readBootPath,
  staticClosure,
  staticImports,
  type BootPath,
  type BuildFiles,
  type Manifest,
  type ModulesFile,
} from "./measure-initial-js"

/**
 * The canonical bundle measurement over a small hand-written build
 * (`measure-fixture/`): an entry with a modulepreload and a classic script,
 * a shell chunk that shares a kit chunk with the sign-in chunk, a deferred
 * content chunk with a heavy dependency, and a find chunk the shell imports
 * dynamically.
 */

const fixture = new URL("./measure-fixture", import.meta.url).pathname
const files = directoryFiles(fixture)
const manifest = JSON.parse(readFileSync(`${fixture}/.vite/manifest.json`, "utf8")) as Manifest
const modules = JSON.parse(readFileSync(`${fixture}/bundle-modules.json`, "utf8")) as ModulesFile

const boot: BootPath = {
  specifiers: new Map([
    ["shell", "./Shell"],
    ["signIn", "../features/signin"],
    ["authFlows", "@inline/auth/flows"],
    ["content", "../features/chat/content-chunk"],
    ["find", "../features/chat/find-chunk"],
  ]),
  firstPaint: { signedIn: ["shell"], signedOut: ["signIn", "authFlows"] },
  afterFirstPaint: ["content"],
}

const memoryFiles = (contents: Record<string, string>): BuildFiles => ({
  read: (file) => {
    const content = contents[file]
    if (content === undefined) throw new Error(`no ${file}`)
    return content
  },
  exists: (file) => file in contents,
})

describe("the import graph of a build", () => {
  it("reads static imports and re-exports, resolved against the importing file, and not dynamic ones", () => {
    const code = `import{a as e}from"./x-1.js";import"../y-2.js";export{b}from"./z-3.js";const f=()=>import("./d-4.js")`
    expect(staticImports(code, "assets/sub/m.js").sort()).toEqual(["assets/sub/x-1.js", "assets/sub/z-3.js", "assets/y-2.js"])
    expect(dynamicImports(code, "assets/sub/m.js")).toEqual(["assets/sub/d-4.js"])
    expect(dynamicImports("import(`./t-5.js`)", "assets/m.js")).toEqual(["assets/t-5.js"])
  })

  it("starts from the page's scripts and modulepreloads, never its stylesheets", () => {
    expect(htmlEntries(files.read("index.html"))).toEqual(["appearance-boot.js", "assets/index-A.js", "assets/shared-B.js"])
  })

  it("follows static imports transitively, and only those", () => {
    expect([...staticClosure(files, ["assets/Shell-S.js"])].sort()).toEqual(["assets/Shell-S.js", "assets/kit-K.js", "assets/shared-B.js"])
  })
})

describe("the boot path", () => {
  it("resolves each chunk name's import specifier to its manifest entry", () => {
    expect(manifestKeyFor("./Shell", manifest)).toBe("src/app/Shell.tsx")
    expect(manifestKeyFor("../features/signin", manifest)).toBe("src/features/signin/index.ts")
    expect(manifestKeyFor("@inline/auth/flows", manifest)).toBe("packages/auth/src/flows/index.ts")
    expect(manifestKeyFor("./Missing", manifest)).toBeUndefined()
  })

  it("resolves a package subpath through the package's exports, as the bundler does", () => {
    // `@inline/ui/menu-kit` is `src/react/menu-kit.tsx` (packages/ui/package.json), not `src/menu-kit`.
    const withKit = { ...manifest, "packages/ui/src/react/menu-kit.tsx": { file: "assets/menu-kit-M.js", isDynamicEntry: true } }
    expect(manifestKeyFor("@inline/ui/menu-kit", withKit)).toBe("packages/ui/src/react/menu-kit.tsx")
  })

  it("reads the app's own table: every first-paint and after-paint name has a literal importer", async () => {
    const path = new URL("../src/app/view-chunks.ts", import.meta.url).pathname
    const real = await readBootPath(path)
    expect(real.firstPaint.signedIn).toContain("shell")
    for (const name of [...real.firstPaint.signedIn, ...real.firstPaint.signedOut, ...real.afterFirstPaint]) {
      expect(real.specifiers.get(name), name).toBeDefined()
    }
    expect(chunkSpecifiers(readFileSync(path, "utf8")).get("shell")).toBe("./Shell")
  })
})

describe("measuring", () => {
  const result = measure({ files, manifest, boot })
  const names = (set: { files: readonly { file: string }[] }) => set.files.map((row) => row.file).sort()

  it("counts the entry closure, plus the classic script", () => {
    expect(names(result.entry)).toEqual(["appearance-boot.js", "assets/index-A.js", "assets/polyfill-P.js", "assets/shared-B.js"])
  })

  it("signed in: the entry plus the shell's static closure", () => {
    expect(result.signedIn.chunks).toEqual(["assets/Shell-S.js"])
    expect(names(result.signedIn)).toEqual([...names(result.entry), "assets/Shell-S.js", "assets/kit-K.js"].sort())
    const sum = result.signedIn.files.reduce((total, row) => total + gzipSize(files.read(row.file)), 0)
    expect(result.signedIn.gzip).toBe(sum)
  })

  it("signed out: the entry plus the sign-in chunk and the flows", () => {
    expect(names(result.signedOut)).toEqual([...names(result.entry), "assets/flows-L.js", "assets/kit-K.js", "assets/signin-I.js"].sort())
  })

  it("deferred chunks cost what they add beyond the signed-in set, whoever imports them", () => {
    const byName = new Map(result.deferred.map((chunk) => [chunk.name, chunk]))
    expect([...byName.keys()].sort()).toEqual(["authFlows", "content", "find", "signIn"])
    // content: itself and heavy-H (kit-K is already loaded); find: itself and heavy-H.
    expect(byName.get("content")?.files).toBe(2)
    expect(byName.get("find")?.files).toBe(2)
    expect(byName.get("content")?.warmed).toBe(true)
    expect(byName.get("find")?.warmed).toBe(false)
  })

  it("fails loudly when a first-paint name is not in the build", () => {
    const broken: BootPath = { ...boot, firstPaint: { signedIn: ["nowhere"], signedOut: [] } }
    expect(() => measure({ files, manifest, boot: broken })).toThrow(/no importer named "nowhere"/)
  })
})

describe("the breakdown", () => {
  it("shares each chunk's real gzip out to its modules, adding up to the set", () => {
    const set = measure({ files, manifest, boot }).signedIn
    const shares = moduleShares(modules, set)
    const total = shares.reduce((sum, share) => sum + share.gzip, 0)
    expect(total).toBeCloseTo(set.gzip, 6)
    const rollup = packageRollup(shares)
    expect(rollup.map((row) => row.name)).toContain("react-dom")
    expect(rollup.map((row) => row.name)).toContain("src/app")
  })

  it("names packages and app folders", () => {
    expect(packageOf("node_modules/react-dom/cjs/x.js")).toBe("react-dom")
    expect(packageOf("node_modules/@stylexjs/stylex/lib/x.mjs")).toBe("@stylexjs/stylex")
    expect(packageOf("packages/ui/src/react/Menu.tsx")).toBe("@inline/ui")
    expect(packageOf("src/features/chat/ChatPane.tsx")).toBe("src/features/chat")
    expect(packageOf("src/app/boot.ts")).toBe("src/app")
    expect(packageOf("../packages/protocol/src/x.ts")).toBe("@inline-chat/protocol")
    expect(packageOf("vite/preload-helper.js")).toBe("(bundler)")
  })
})

describe("entry isolation", () => {
  const map = (chunks: Record<string, string[]>): ModulesFile => ({
    chunks: Object.entries(chunks).map(([fileName, ids]) => ({ fileName, modules: ids.map((id) => ({ id, rendered: 1, gzip: 1 })) })),
  })
  const page = (script: string) => `<script type="module" src="/${script}"></script>`

  it("passes the fixture build", () => {
    expect(checkEntries(files, ["index.html"], modules)).toEqual([])
  })

  it("catches a lab page whose shared chunk swallowed the app entry", () => {
    const build = memoryFiles({
      "index.html": page("assets/index.js"),
      "lab-emoji.html": page("assets/lab-emoji.js"),
      "assets/index.js": `import"./boot.js";`,
      "assets/lab-emoji.js": `import{a}from"./boot.js";`,
      "assets/boot.js": "export const a=1",
    })
    const problems = checkEntries(build, ["index.html", "lab-emoji.html"], map({
      "assets/index.js": [],
      "assets/lab-emoji.js": ["src/lab/emoji/main.tsx"],
      "assets/boot.js": ["src/main.tsx", "src/app/boot.ts"],
    }))
    expect(problems).toEqual(["lab-emoji.html loads the app entry (src/main.tsx)"])
  })

  it("catches lab or demo code reachable from a production index.html, statically or dynamically", () => {
    const build = memoryFiles({
      "index.html": page("assets/index.js"),
      "assets/index.js": "const d=()=>import(`./demo.js`)",
      "assets/demo.js": "export const x=1",
    })
    const problems = checkEntries(build, ["index.html"], map({ "assets/index.js": ["src/main.tsx"], "assets/demo.js": ["src/core/demo/connect-demo.ts"] }))
    expect(problems).toEqual(["index.html can reach demo code (src/core/demo/connect-demo.ts)"])
  })

  it("catches the __inlineApp hook or the demo parameter reachable from a production index.html", () => {
    const build = memoryFiles({
      "index.html": page("assets/index.js"),
      "assets/index.js": "const d=()=>import(`./dev.js`)",
      "assets/dev.js": "export const x=1",
    })
    const chunks = { "assets/index.js": ["src/main.tsx", "src/app/demo-params.ts"], "assets/dev.js": ["src/app/dev-snapshot.ts"] }
    expect(checkEntries(build, ["index.html"], map(chunks))).toEqual([
      "index.html can reach demo code (src/app/demo-params.ts)",
      "index.html can reach demo code (src/app/dev-snapshot.ts)",
    ])
    // The labs build compiles both in on purpose.
    const labs = memoryFiles({
      "index.html": page("assets/index.js"),
      "assets/index.js": "const d=()=>import(`./dev.js`)",
      "assets/dev.js": "export const x=1",
      "lab-emoji.html": page("assets/lab.js"),
      "assets/lab.js": "",
    })
    expect(checkEntries(labs, ["index.html", "lab-emoji.html"], map({ ...chunks, "assets/lab.js": ["src/lab/emoji/main.ts"] }))).toEqual([])
  })
})
