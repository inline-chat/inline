import { vitePlugin as remix } from "@remix-run/dev"
import { defineConfig } from "vite"
import tsconfigPaths from "vite-tsconfig-paths"
import styleX from "vite-plugin-stylex"

export default defineConfig({
  plugins: [
    remix({
      future: {
        v3_fetcherPersist: true,
        v3_relativeSplatPath: true,
        v3_throwAbortReason: true,
      },
    }),
    tsconfigPaths(),
    styleX({}),
  ],
})
