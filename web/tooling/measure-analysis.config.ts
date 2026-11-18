/**
 * The production build plus the module map, for the per-module breakdown of
 * the initial set. Never used by `bun run build`. Build into a scratch
 * directory, then measure:
 *
 *   bunx vite build -c tooling/measure-analysis.config.ts --outDir <scratch>
 *   bun run size <scratch> --modules
 */

import { defineConfig, mergeConfig } from "vite"
import base from "../vite.config"
import { measureModulesPlugin, stubModulesPlugin } from "./measure-modules-plugin"

// Experiment (MEASURE_STUB=path,path): those modules (paths relative to web/)
// are replaced by empty stand-ins with the same exports, to measure what
// deferring them would save. Never a shippable build.
const stubs = (process.env.MEASURE_STUB ?? "").split(",").filter(Boolean)

export default mergeConfig(
  base,
  defineConfig({
    plugins: [measureModulesPlugin(), ...(stubs.length > 0 ? [stubModulesPlugin(stubs)] : [])],
    build: {
      manifest: true,
      // Experiment (MEASURE_SRC_PURE=1): web/src declared side-effect free, except the entry, CSS and workers.
      ...(process.env.MEASURE_SRC_PURE === "1"
        ? {
            rolldownOptions: {
              treeshake: {
                moduleSideEffects: (id: string) =>
                  id.includes("/web/src/") && !/\.css$|\/main\.tsx$|\.worker\.ts$|\/src\/sw\//.test(id) ? false : undefined,
              },
            },
          }
        : {}),
    },
  }),
)
