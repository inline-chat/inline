import { readFileSync } from "node:fs"
import babel from "@rolldown/plugin-babel"
import stylex from "@stylexjs/unplugin"
import react, { reactCompilerPreset } from "@vitejs/plugin-react"
import { defineConfig, type HtmlTagDescriptor, type Plugin } from "vite"
import { serviceWorkerPlugin } from "./tooling/service-worker-plugin"

// The production document policy. Hosting adds the header-only directives
// (frame-ancestors, report-to); everything a meta tag can carry lives here so
// a static build is locked down wherever it is served.
const contentSecurityPolicy = [
  "default-src 'self'",
  // sqlite-wasm compiles WebAssembly; nothing else may evaluate code.
  "script-src 'self' 'wasm-unsafe-eval'",
  "style-src 'self'",
  "img-src 'self' data: blob: https:",
  "media-src 'self' blob: https:",
  "font-src 'self'",
  "connect-src 'self' https://api.inline.chat wss://api.inline.chat",
  "worker-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "require-trusted-types-for 'script'",
  // One named policy, which only mints same-origin script URLs for the core
  // worker and the service worker (src/sw/trusted-script-url.ts). No default
  // policy is allowed, so nothing else can pass a string to a script sink.
  "trusted-types inline-script-url",
].join("; ")

const sourceDirectory = new URL("./src", import.meta.url).pathname
const packagesDirectory = new URL("./packages", import.meta.url).pathname

const appearanceBootPath = new URL("./packages/ui/src/theme/boot.js", import.meta.url)

/**
 * The saved appearance must be applied before first paint, and the content
 * policy forbids inline scripts. So a tiny same-origin classic script in
 * <head> does it (packages/ui/src/theme/README.md).
 */
function appearanceBoot(): Plugin {
  return {
    name: "inline-appearance-boot",
    buildStart() {
      if (this.meta.watchMode) return
      this.emitFile({
        type: "asset",
        fileName: "appearance-boot.js",
        source: readFileSync(appearanceBootPath, "utf8"),
      })
    },
    transformIndexHtml(_html, context): HtmlTagDescriptor[] {
      const src = context.server ? "/packages/ui/src/theme/boot.js" : "/appearance-boot.js"
      return [{ tag: "script", attrs: { src }, injectTo: "head-prepend" }]
    },
  }
}

function documentPolicy(): Plugin {
  return {
    name: "inline-document-policy",
    transformIndexHtml(_html, context): HtmlTagDescriptor[] {
      if (context.server) {
        // StyleX serves its dev stylesheet from a virtual endpoint.
        return [{ tag: "link", attrs: { rel: "stylesheet", href: "/virtual:stylex.css" }, injectTo: "head" }]
      }
      return [
        {
          tag: "meta",
          attrs: { "http-equiv": "Content-Security-Policy", content: contentSecurityPolicy },
          injectTo: "head-prepend",
        },
      ]
    },
  }
}

/**
 * Chunking for the initial set (web/docs/performance.md, "Measuring the
 * initial JavaScript"). Rolldown's automatic chunking splits every module
 * the entry shares with a dynamic chunk into a small file of its own, so the
 * entry's closure was about 20 files, each gzipped alone. The `boot` group
 * puts that code back into one file without moving a module into or out of
 * any load path: it holds the modules Rolldown tags `$initial` (statically
 * imported by an entry, after tree shaking) that are also in the app entry's
 * import graph, which is always loaded first by every path.
 *
 * Never an entry module itself: an entry's top-level code (`main.tsx` boots
 * and renders the app) must run only for its own page, so it stays in its
 * own entry chunk and a page that shares the group's modules never runs it.
 * The labs build turns the group off (`tooling/vite.labs.config.ts`), and
 * `bun run size --entries` checks both builds for it.
 */
type ModuleGraph = {
  getModuleInfo(id: string): { readonly importedIds: readonly string[]; readonly isEntry: boolean } | null
}

const appEntry = new URL("./src/main.tsx", import.meta.url).pathname

/** The app entry's import graph (an over-approximation; `$initial` makes it exact), once per chunking pass. */
const appGraph = (() => {
  let cache: { key: object; ids: Set<string> } | undefined
  return (graph: ModuleGraph): Set<string> | undefined => {
    const key = graph.getModuleInfo(appEntry)
    if (!key) return undefined
    if (cache?.key !== key) {
      const ids = new Set<string>()
      const stack = [appEntry]
      while (stack.length > 0) {
        const id = stack.pop()
        if (id === undefined || ids.has(id)) continue
        ids.add(id)
        for (const next of graph.getModuleInfo(id)?.importedIds ?? []) stack.push(next)
      }
      cache = { key, ids }
    }
    return cache.ids
  }
})()

const bootGroup = (id: string, graph: ModuleGraph): string | null =>
  !graph.getModuleInfo(id)?.isEntry && appGraph(graph)?.has(id) ? "boot" : null

/**
 * The `Shell` group: the signed-in shell's chunk together with every module
 * it statically imports that is not in `boot`. Automatic chunking split the
 * modules the shell shares with deferred chunks (settings, content, chat
 * info, ...) into a dozen small files, each gzipped alone; the signed-in set
 * then loaded all of them before its first paint anyway. One file holds them
 * now, and a deferred chunk that shares one imports the shell's file, which
 * is always there before it (every such chunk is requested by the signed-in
 * shell or after it).
 *
 * Never a module that can load without the shell: anything reachable from
 * the chunks requested while signed out or before any shell exists (the
 * sign-in screen, the auth flows, the boot's own warm-up: service worker,
 * storage sweep, notifications) stays where automatic chunking puts it, so
 * signing out never downloads or runs the shell. That set is closed under
 * imports, so the group never forms a cycle with it.
 */
const shellEntry = new URL("./src/app/Shell.tsx", import.meta.url).pathname
const withoutShell = [
  "./src/features/signin/index.ts",
  "./packages/auth/src/flows/index.ts",
  "./src/sw/register.ts",
  "./src/core/account-storage-sweep.ts",
  "./src/app/notifications-chunk.ts",
].map((path) => new URL(path, import.meta.url).pathname)

type FullModuleGraph = {
  getModuleInfo(
    id: string,
  ): { readonly importedIds: readonly string[]; readonly dynamicallyImportedIds: readonly string[]; readonly isEntry: boolean } | null
}

const graphFrom = (graph: FullModuleGraph, starts: readonly string[], dynamic: boolean): Set<string> => {
  const ids = new Set<string>()
  const stack = [...starts]
  while (stack.length > 0) {
    const id = stack.pop()
    if (id === undefined || ids.has(id)) continue
    const info = graph.getModuleInfo(id)
    if (!info) continue
    ids.add(id)
    if (!dynamic && process.env.NOBARREL && /\/index\.tsx?$/.test(id) && id !== shellEntry) continue
    for (const next of info.importedIds) stack.push(next)
    if (dynamic) for (const next of info.dynamicallyImportedIds) stack.push(next)
  }
  return ids
}

const shellGraph = (() => {
  let cache: { key: object; ids: Set<string> } | undefined
  return (graph: FullModuleGraph): Set<string> | undefined => {
    const key = graph.getModuleInfo(shellEntry)
    if (!key) return undefined
    if (cache?.key !== key) {
      const outside = graphFrom(graph, withoutShell, true)
      const ids = graphFrom(graph, [shellEntry], false)
      for (const id of outside) ids.delete(id)
      cache = { key, ids }
    }
    return cache.ids
  }
})()

const shellGroup = (id: string, graph: FullModuleGraph): string | null => (shellGraph(graph)?.has(id) ? "Shell" : null)

// Build IDs sort lexically, newest last: the newest build leads when two
// builds of the app meet (see web/docs/architecture.md, "Version skew").
const buildId = new Date().toISOString()

// The demo (a fake signed-in account against a simulated server, plus the
// `__inlineApp` automation hook) is compiled in only by the dev server
// (`import.meta.env.DEV`) and the labs build, which defines `__INLINE_DEMO__`
// as true (tooling/vite.labs.config.ts). It used to be switched on by an
// environment variable, which a stray CI variable could have turned on in a
// production build; that variable is refused outright now.
if (process.env.VITE_ENABLE_DEMO !== undefined) {
  throw new Error(
    "VITE_ENABLE_DEMO is set in the environment. The demo is no longer an environment switch: it is compiled in only by the dev server and the labs build (tooling/vite.labs.config.ts). Unset it.",
  )
}

export default defineConfig({
  define: {
    __INLINE_BUILD_ID__: JSON.stringify(buildId),
    // Never true here: only the labs build overrides it.
    __INLINE_DEMO__: "false",
  },
  plugins: [
    stylex.vite({
      devMode: "full",
      useCSSLayers: true,
      // StyleX resolves token imports itself, so it needs the alias too.
      aliases: {
        "~/*": [`${sourceDirectory}/*`],
        "@inline/ui/tokens/*": [`${packagesDirectory}/ui/src/tokens/*`],
      },
    }),
    react(),
    babel({ presets: [reactCompilerPreset()] }),
    appearanceBoot(),
    documentPolicy(),
    serviceWorkerPlugin({ buildId, killSwitch: process.env.INLINE_SW_KILL === "1" }),
  ],
  resolve: {
    alias: {
      "~": sourceDirectory,
    },
    dedupe: ["react", "react-dom"],
  },
  // sqlite-wasm locates its .wasm file relative to its own module; pre-bundling
  // moves the module and breaks that.
  optimizeDeps: {
    exclude: ["@sqlite.org/sqlite-wasm"],
  },
  build: {
    rolldownOptions: {
      ...(process.env.SHELLENTRY ? { input: { index: new URL("./index.html", import.meta.url).pathname, Shell: shellEntry } } : {}),
      output: {
        codeSplitting: {
          groups: [
            { name: bootGroup, tags: ["$initial"] },
            // After `boot`, which keeps its modules; dependencies are not pulled in, so nothing outside the shell's own set joins it.
            { name: shellGroup, includeDependenciesRecursively: false },
          ],
        },
      },
    },
  },
  worker: {
    format: "es",
  },
  server: {
    port: 8001,
    strictPort: true,
  },
  preview: {
    port: 8001,
    strictPort: true,
  },
})
