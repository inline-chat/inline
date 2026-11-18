// Tests for web/tooling/precache-manifest.ts, kept here because the app's Vitest
// config only collects src/**.
import { describe, expect, it } from "vitest"
import { buildPrecacheManifest, revisionOfContent, shellPolicyOf, type EmittedFile } from "../../tooling/precache-manifest"
import { revisionOf } from "./protocol"

/** The shape of a real Vite 8 build of this app with lab pages as extra inputs. */
const bundle: EmittedFile[] = [
  {
    fileName: "index.html",
    content:
      '<script type="module" crossorigin src="/assets/index-AAAA.js"></script><link rel="stylesheet" crossorigin href="/assets/index-CSS1.css">',
  },
  {
    fileName: "assets/index-AAAA.js",
    content: 'import"./modulepreload-polyfill-PPPP.js";new Worker(new URL("/assets/core.worker-WWWW.js",import.meta.url))',
    imports: ["assets/modulepreload-polyfill-PPPP.js"],
    dynamicImports: ["assets/settings-SSSS.js"],
  },
  { fileName: "assets/settings-SSSS.js", content: "export{}" },
  { fileName: "assets/modulepreload-polyfill-PPPP.js", content: "polyfill" },
  { fileName: "assets/index-CSS1.css", content: "body{}" },
  // Vite emits worker bundles as assets of the main build.
  { fileName: "assets/core.worker-WWWW.js", content: "import(`./dist-DDDD.js`)" },
  { fileName: "assets/dist-DDDD.js", content: 'new URL("sqlite3-QQQQ.wasm",import.meta.url)' },
  { fileName: "assets/sqlite3-QQQQ.wasm", content: new Uint8Array([0, 97, 115, 109]) },
  { fileName: "assets/index-AAAA.js.map", content: "{}" },
  { fileName: "lab-core.html", content: '<script src="/assets/lab-core-LLLL.js"></script>' },
  { fileName: "assets/lab-core-LLLL.js", content: "import './modulepreload-polyfill-PPPP.js'", imports: ["assets/modulepreload-polyfill-PPPP.js"] },
  { fileName: ".vite/manifest.json", content: "{}" },
  { fileName: "sw.js", content: "old worker" },
]

describe("buildPrecacheManifest", () => {
  it("lists the shell and everything it reaches, and nothing else", () => {
    const manifest = buildPrecacheManifest(bundle, { base: "/" })
    expect(manifest.shell).toMatchObject({ url: "/", revision: revisionOfContent(bundle[0]?.content ?? "") })
    expect(manifest.assets.map((entry) => entry.url)).toEqual([
      "/assets/core.worker-WWWW.js",
      "/assets/dist-DDDD.js",
      "/assets/index-AAAA.js",
      "/assets/index-CSS1.css",
      "/assets/modulepreload-polyfill-PPPP.js",
      "/assets/settings-SSSS.js",
      "/assets/sqlite3-QQQQ.wasm",
    ])
    expect(manifest.skipped).toEqual([
      ".vite/manifest.json",
      "assets/index-AAAA.js.map",
      "assets/lab-core-LLLL.js",
      "lab-core.html",
      "sw.js",
    ])
  })

  it("honors base, extra exclusions and another shell", () => {
    const manifest = buildPrecacheManifest(bundle, {
      base: "/app",
      exclude: (name) => name.endsWith(".wasm"),
    })
    expect(manifest.shell.url).toBe("/app/")
    expect(manifest.assets.map((entry) => entry.url)).toContain("/app/assets/index-AAAA.js")
    expect(manifest.assets.map((entry) => entry.url)).not.toContain("/app/assets/sqlite3-QQQQ.wasm")
    expect(() => buildPrecacheManifest(bundle, { base: "/", shellHtml: "missing.html" })).toThrow("missing.html")
  })

  it("computes revisions the service worker reproduces with Web Crypto", async () => {
    const bytes = new TextEncoder().encode("<!doctype html>")
    const inWorker = revisionOf(await crypto.subtle.digest("SHA-256", bytes))
    expect(revisionOfContent(bytes)).toBe(inWorker)
    expect(revisionOfContent("<!doctype html>")).toBe(inWorker)
    expect(buildPrecacheManifest(bundle, { base: "/" }).assets.find((entry) => entry.url.endsWith(".wasm"))?.size).toBe(4)
  })
})

describe("shellPolicyOf", () => {
  const policy = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'"

  it("reads the policy as Vite writes it, and as other serializers escape it", () => {
    expect(shellPolicyOf(`<head><meta http-equiv="Content-Security-Policy" content="${policy}"></head>`)).toBe(policy)
    expect(
      shellPolicyOf(`<META content="${policy.replaceAll("'", "&#39;")}" HTTP-EQUIV='content-security-policy'>`),
    ).toBe(policy)
    expect(buildPrecacheManifest([{ fileName: "index.html", content: `<meta http-equiv="Content-Security-Policy" content="${policy}">` }], { base: "/" }).shellPolicy).toBe(policy)
  })

  it("is absent without a policy meta tag, and refuses two", () => {
    expect(shellPolicyOf('<meta charset="utf-8"><meta name="viewport" content="width=device-width">')).toBeUndefined()
    expect(buildPrecacheManifest(bundle, { base: "/" }).shellPolicy).toBeUndefined()
    const two = `<meta http-equiv="Content-Security-Policy" content="a"><meta http-equiv="Content-Security-Policy" content="b">`
    expect(() => shellPolicyOf(two)).toThrow("more than one")
  })
})
