import babel from "@rolldown/plugin-babel"
import { reactCompilerPreset } from "@vitejs/plugin-react"
import { defineConfig } from "vitest/config"

// The React tests run twice: as written, and compiled by the React Compiler
// the way the app compiles its views (web/vite.config.ts). The compiler
// plugins come from web's devDependencies. The preset only applies itself to
// client environments; Vitest's runner is a server consumer, so lift that.
const compiler = reactCompilerPreset()
const compilerEverywhere = { ...compiler, rolldown: { ...compiler.rolldown, applyToEnvironmentHook: () => true } }

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "plain",
          environment: "node",
          include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
        },
      },
      {
        // Vitest's types are on Vite 7, the babel plugin's on Vite 8; the runtime accepts it.
        plugins: [babel({ presets: [compilerEverywhere] }) as never],
        test: {
          name: "compiler",
          environment: "node",
          env: { REACT_COMPILER: "1" },
          include: ["src/react/**/*.test.tsx"],
        },
      },
    ],
  },
})
