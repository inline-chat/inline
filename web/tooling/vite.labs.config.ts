/**
 * Production build of the app plus every lab page, for checking things that
 * only show up in a production build: the content policy with Trusted Types,
 * the service worker, the core worker's bundled URL, real bundle sizes.
 * Not used by `bun run build`; lab pages never ship.
 *
 *   bunx vite build -c tooling/vite.labs.config.ts
 *   bunx vite preview -c tooling/vite.labs.config.ts
 *   then open http://localhost:8001/lab-core.html (or any lab-*.html)
 */

import { existsSync, readdirSync } from "node:fs"
import { defineConfig, mergeConfig, type Plugin, type UserConfig } from "vite"
import base from "../vite.config"
import { measureModulesPlugin } from "./measure-modules-plugin"

// Labs must never talk to the production API. Vite puts VITE_* variables from
// the environment into `import.meta.env`, which `@inline/config` reads, so
// every lab build points at the local development server address. The
// production content policy then refuses that connection: labs stay offline.
process.env.VITE_SERVER_URL = "http://localhost:8000"

const root = new URL("..", import.meta.url).pathname
// A lab page counts once its entry script exists, so a lab that is still
// being written does not break the build.
const labs = readdirSync(root).filter((name) => {
  const match = /^lab-([a-z-]+)\.html$/.exec(name)
  if (!match) return false
  const entry = `${root}src/lab/${match[1]}/main`
  return existsSync(`${entry}.ts`) || existsSync(`${entry}.tsx`)
})

/**
 * StyleX collects every page's rules into the app's one stylesheet, which
 * only index.html links. Lab pages need it too.
 */
const linkAppStylesheet = (): Plugin => ({
  name: "labs-link-app-stylesheet",
  apply: "build",
  transformIndexHtml: {
    order: "post",
    handler(html, context) {
      const sheet = Object.keys(context.bundle ?? {}).find((file) => /assets\/index-[^/]+\.css$/.test(file))
      if (!sheet || html.includes(sheet)) return html
      return [{ tag: "link", attrs: { rel: "stylesheet", href: `/${sheet}` }, injectTo: "head" }]
    },
  },
})

/**
 * The production config's chunk groups are for the app's one entry; with
 * twenty lab entries they would only couple pages. Labs use Rolldown's
 * automatic chunking, so no lab page shares a file with the app's boot.
 * `bun run size <labs out> --entries` checks it (the module map below).
 */
const withoutAppChunkGroups = (config: UserConfig): UserConfig => {
  const rolldownOptions = config.build?.rolldownOptions
  const output = rolldownOptions?.output
  if (rolldownOptions && output && !Array.isArray(output)) {
    // A copy: the merged config shares this object with the production config.
    rolldownOptions.output = { ...output, codeSplitting: true }
  }
  return config
}

export default withoutAppChunkGroups(mergeConfig(
  base,
  defineConfig({
    // The labs build may boot the app against the demo core (`/?demo=small`)
    // and exposes `__inlineApp`. The production config defines this false.
    define: { __INLINE_DEMO__: "true" },
    plugins: [linkAppStylesheet(), measureModulesPlugin()],
    build: {
      outDir: "dist/labs",
      rolldownOptions: {
        input: Object.fromEntries(
          ["index.html", ...labs].map((file) => [file.replace(/\.html$/, ""), file]),
        ),
      },
    },
  }),
))
