import eslint from "@eslint/js"
import tseslint from "typescript-eslint"
import react from "eslint-plugin-react"
import globals from "globals"

// Define files to include rather than exclude for better performance
const files = ["{server,website}/**/*.{js,jsx,mjs,cjs,ts,tsx}"]
const ignores = ["**/node_modules/**", "**/*.d.ts", "server/build/**", "server/dist/**"]

// eslint.config.js
export default tseslint.config(
  {
    ...tseslint.configs.base,
    files,
    ignores,
  },

  {
    name: "base",
    plugins: {
      react,
      tseslint: tseslint.plugin,
    },
    ...react.configs.flat.recommended,
    ...react.configs.flat["jsx-runtime"],
    languageOptions: {
      ...react.configs.flat.recommended.languageOptions,
      ...react.configs.flat["jsx-runtime"].languageOptions,
      globals: {
        ...globals.browser,
      },
    },
    settings: {
      react: {
        version: "18",
      },
    },
    files,
    ignores,
  },

  {
    name: "server",
    rules: {
      "no-console": ["error", { allow: ["error", "warn", "debug", "trace", "info"] }],
    },
    files: ["server/**/*.{js,jsx,mjs,cjs,ts,tsx}"],
    ignores,
  },
)
