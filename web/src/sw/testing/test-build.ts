/**
 * Fake builds of the app: a shell, an entry chunk, a lazy chunk, the core
 * worker and the SQLite WASM, with hashed names and a service worker config
 * made by the same manifest code the build plugin uses.
 */

import { buildPrecacheManifest, type EmittedFile } from "../../../tooling/precache-manifest"
import type { ServiceWorkerConfig } from "../protocol"
import type { FakeNetwork } from "./fake-network"

export interface TestBuild {
  readonly buildId: string
  readonly config: ServiceWorkerConfig
  readonly files: Readonly<Record<string, string | Uint8Array>>
  /** Paths by role. */
  readonly paths: {
    readonly entry: string
    readonly lazy: string
    readonly worker: string
    readonly wasm: string
    readonly css: string
    readonly shared: string
  }
}

export interface TestBuildOptions {
  readonly killSwitch?: boolean
}

/** `n` sorts with the build: build IDs are compared lexically. */
/** The content policy the test shell carries in its meta tag. */
export const TEST_SHELL_POLICY = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; require-trusted-types-for 'script'"
/** As an attribute value, with the quotes escaped the way an HTML serializer may. */
const TEST_SHELL_POLICY_HTML = TEST_SHELL_POLICY.replaceAll("'", "&#39;")

export const testBuild = (n: number, options: TestBuildOptions = {}): TestBuild => {
  const buildId = `2026-11-17T00:00:${String(n).padStart(2, "0")}.000Z`
  const tag = `b${n}`
  const names = {
    entry: `assets/index-${tag}.js`,
    lazy: `assets/settings-${tag}.js`,
    worker: `assets/core.worker-${tag}.js`,
    wasm: `assets/sqlite3-${tag}.wasm`,
    css: `assets/index-${tag}.css`,
    // Identical in every build: same name, same bytes.
    shared: "assets/vendor-same.js",
  }
  const wasm = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, n])
  const emitted: EmittedFile[] = [
    {
      fileName: "index.html",
      content: `<!doctype html><meta http-equiv="Content-Security-Policy" content="${TEST_SHELL_POLICY_HTML}"><title>Inline ${buildId}</title><script type="module" src="/${names.entry}"></script><link rel="stylesheet" href="/${names.css}">`,
    },
    {
      fileName: names.entry,
      content: `import "./vendor-same.js";const build="${buildId}";const lazy=()=>import("./settings-${tag}.js");new Worker("/${names.worker}")`,
      imports: [names.shared],
      dynamicImports: [names.lazy],
    },
    { fileName: names.lazy, content: `export const settings="${tag}"` },
    { fileName: names.shared, content: "export const vendor=1" },
    { fileName: names.css, content: `body{--build:"${tag}"}` },
    { fileName: names.worker, content: `const wasm=new URL("/${names.wasm}",import.meta.url)` },
    { fileName: names.wasm, content: wasm },
    { fileName: `${names.entry}.map`, content: "{}" },
    { fileName: "lab-sw.html", content: `<script src="/assets/lab-${tag}.js"></script>` },
    { fileName: `assets/lab-${tag}.js`, content: "lab" },
  ]
  const manifest = buildPrecacheManifest(emitted, { base: "/" })
  const config: ServiceWorkerConfig = {
    buildId,
    shell: manifest.shell,
    assets: manifest.assets,
    ...(manifest.shellPolicy !== undefined ? { shellPolicy: manifest.shellPolicy } : {}),
    assetsPath: "/assets/",
    navigationDenylist: ["/__"],
    killSwitch: options.killSwitch === true,
  }
  const files: Record<string, string | Uint8Array> = {}
  for (const file of emitted) files[`/${file.fileName}`] = file.content
  return {
    buildId,
    config,
    files,
    paths: {
      entry: `/${names.entry}`,
      lazy: `/${names.lazy}`,
      worker: `/${names.worker}`,
      wasm: `/${names.wasm}`,
      css: `/${names.css}`,
      shared: `/${names.shared}`,
    },
  }
}

/**
 * Puts a build on the network the way a static host would: `/` serves the
 * shell, files of earlier builds stay (assets are uploaded additively).
 */
export const host = (network: FakeNetwork, build: TestBuild): void => {
  for (const [path, content] of Object.entries(build.files)) {
    const headers: Record<string, string> = path.endsWith(".wasm")
      ? { "content-type": "application/wasm" }
      : path.endsWith(".html")
        ? { "content-type": "text/html", "content-encoding": "br" }
        : { "content-type": "text/javascript" }
    network.serve(path, content, headers)
  }
  network.serve("/", build.files["/index.html"] ?? "", { "content-type": "text/html", "x-frame-options": "DENY" })
  network.serve("/sw.js", `// ${build.buildId}`, { "content-type": "text/javascript" })
}
