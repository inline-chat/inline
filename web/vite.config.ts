import { defineConfig } from "vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import tsconfigPaths from "vite-tsconfig-paths"
import tailwindcss from "@tailwindcss/vite"
import stylex from "vite-plugin-stylex"

export default defineConfig({
  server: {
    port: 3000,
  },
  css: {
    postcss: "./postcss.config.cjs", // Vite will automatically pick this up
  },
  plugins: [
    tailwindcss(),
    // Enables Vite to resolve imports using path aliases.
    tsconfigPaths(),
    stylex({
      useCSSLayers: true,
    }),
    tanstackStart({
      srcDirectory: "src", // This is the default
      router: {
        // Specifies the directory TanStack Router uses for your routes.
        routesDirectory: "routes", // Defaults to "routes", relative to srcDirectory
      },
    }),
    viteReact({
      // babel: {
      //   plugins: [
      //     [
      //       "@stylexjs/babel-plugin",
      //       {
      //         dev: process.env.NODE_ENV === "development",
      //         runtimeInjection: false,
      //         genConditionalClasses: true,
      //         treeshakeCompensation: true,
      //         useRemForFontSize: false,
      //         // unstable_moduleResolution: {
      //         //   type: "commonJS",
      //         // },
      //       },
      //     ],
      //   ],
      // },
    }),
  ],
})
