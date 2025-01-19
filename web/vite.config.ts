import { reactRouter } from "@react-router/dev/vite"
import autoprefixer from "autoprefixer"
import { defineConfig } from "vite"
import tsconfigPaths from "vite-tsconfig-paths"
import styleX from "vite-plugin-stylex"

export default defineConfig({
  css: {
    postcss: {
      plugins: [autoprefixer],
    },
  },
  plugins: [
    reactRouter(),
    tsconfigPaths(),
    styleX({
      // for now, it's easier to not use them
      useCSSLayers: false,
    }),
  ],
})
