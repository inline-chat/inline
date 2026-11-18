/**
 * Emits the service worker for a production build.
 *
 * After every other plugin has finished the bundle (`generateBundle`, order
 * `post`, so Vite's HTML and worker outputs are in it), it:
 *
 * 1. builds the precache manifest from the emitted files
 *    (`precache-manifest.ts`): the shell HTML under a revision of its bytes,
 *    the JS and CSS it reaches, the core worker, its chunks and the SQLite WASM;
 * 2. builds `src/sw/sw-entry.ts` in a separate, config-free Vite build as one
 *    classic script with the manifest injected as `__INLINE_SW_CONFIG__`, and
 *    fails the build if the worker pulled in any module outside `src/sw/`;
 * 3. emits it unhashed at the site root (`/sw.js`).
 *
 * It does nothing in dev. Wiring: `web/src/sw/README.md`.
 */

import { fileURLToPath } from "node:url"
import { build, type Plugin, type ResolvedConfig, type Rollup } from "vite"
import type { ServiceWorkerConfig } from "../src/sw/protocol"
import { buildPrecacheManifest, type EmittedFile, type PrecacheManifest } from "./precache-manifest"

export interface ServiceWorkerPluginOptions {
  /**
   * The app build: the same value the app gets as `__INLINE_BUILD_ID__` and
   * passes to `registerServiceWorker`. Names the worker's cache. Build IDs sort
   * lexically, newest last.
   */
  readonly buildId: string
  /** Default `sw.js`, at the site root. */
  readonly fileName?: string
  /** Default `index.html`. */
  readonly shellHtml?: string
  /**
   * Navigations under these path prefixes are never answered with the shell.
   * Paths whose last segment has a dot (`/lab-sw.html`, `/robots.txt`) never
   * are either. Default `["/__"]`.
   */
  readonly navigationDenylist?: readonly string[]
  /** More emitted files to leave out of the precache. */
  readonly exclude?: (fileName: string) => boolean
  /**
   * Emit a worker that deletes every cache it owns and unregisters, instead of
   * the normal one. See README, "Kill switch".
   */
  readonly killSwitch?: boolean
  /** Called with the result, for checks and reports. */
  readonly onManifest?: (result: { readonly manifest: PrecacheManifest; readonly config: ServiceWorkerConfig; readonly code: string }) => void
}

const swDirectory = fileURLToPath(new URL("../src/sw/", import.meta.url))
const defaultEntry = fileURLToPath(new URL("../src/sw/sw-entry.ts", import.meta.url))

const toEmittedFile = (file: Rollup.OutputChunk | Rollup.OutputAsset): EmittedFile =>
  file.type === "chunk"
    ? { fileName: file.fileName, content: file.code, imports: file.imports, dynamicImports: file.dynamicImports }
    : { fileName: file.fileName, content: file.source }

/** Builds the worker script on its own: no app config, no app plugins, one classic script. */
const buildWorkerScript = async (
  config: ServiceWorkerConfig,
  appConfig: ResolvedConfig,
  fileName: string,
): Promise<string> => {
  const result = await build({
    configFile: false,
    envDir: false,
    root: appConfig.root,
    mode: appConfig.mode,
    logLevel: "warn",
    publicDir: false,
    define: { __INLINE_SW_CONFIG__: JSON.stringify(config) },
    build: {
      write: false,
      emptyOutDir: false,
      copyPublicDir: false,
      minify: appConfig.build.minify !== false,
      sourcemap: false,
      target: "es2022",
      modulePreload: false,
      reportCompressedSize: false,
      lib: { entry: defaultEntry, formats: ["iife"], name: "inlineServiceWorker", fileName: () => fileName },
    },
  })
  const outputs = (Array.isArray(result) ? result : [result]) as Rollup.RollupOutput[]
  const chunks = outputs.flatMap((output) => output.output).filter((file) => file.type === "chunk")
  const [chunk, ...extra] = chunks
  if (!chunk || extra.length > 0) throw new Error("service worker: expected exactly one chunk")
  const outside = chunk.moduleIds.filter((id) => !id.startsWith(swDirectory) && !id.startsWith("\0"))
  if (outside.length > 0) {
    throw new Error(`service worker: imports outside src/sw are not allowed: ${outside.join(", ")}`)
  }
  return chunk.code
}

export const serviceWorkerPlugin = (options: ServiceWorkerPluginOptions): Plugin => {
  const fileName = options.fileName ?? "sw.js"
  let appConfig: ResolvedConfig | null = null

  return {
    name: "inline-service-worker",
    apply: "build",
    configResolved(resolved) {
      appConfig = resolved
    },
    generateBundle: {
      order: "post",
      async handler(_outputOptions, bundle) {
        if (!appConfig || appConfig.build.ssr) return
        const manifest = buildPrecacheManifest(Object.values(bundle).map(toEmittedFile), {
          base: appConfig.base,
          shellHtml: options.shellHtml,
          serviceWorkerFileName: fileName,
          exclude: options.exclude,
        })
        const base = appConfig.base.endsWith("/") ? appConfig.base : `${appConfig.base}/`
        const config: ServiceWorkerConfig = {
          buildId: options.buildId,
          shell: manifest.shell,
          ...(manifest.shellPolicy !== undefined ? { shellPolicy: manifest.shellPolicy } : {}),
          assets: manifest.assets,
          assetsPath: `${base}${appConfig.build.assetsDir}/`,
          navigationDenylist: options.navigationDenylist ?? ["/__"],
          killSwitch: options.killSwitch === true,
        }
        const code = await buildWorkerScript(config, appConfig, fileName)
        this.emitFile({ type: "asset", fileName, source: code })
        const bytes = manifest.assets.reduce((sum, entry) => sum + entry.size, manifest.shell.size)
        appConfig.logger.info(
          config.killSwitch
            ? `service worker: ${fileName} is the kill switch (deletes its caches and unregisters)`
            : `service worker: ${fileName} precaches ${manifest.assets.length + 1} files, ${(bytes / 1024).toFixed(1)} kB`,
        )
        options.onManifest?.({ manifest, config, code })
      },
    },
  }
}
