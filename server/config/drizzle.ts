import { defineConfig } from "drizzle-kit"
import { DATABASE_URL } from "../src/env"
import { resolve } from "path"

export default defineConfig({
  schema: resolve(__dirname, "../src/db/schema/index.ts"),
  out: resolve(__dirname, "../drizzle"),
  dialect: "postgresql",
  dbCredentials: {
    url: DATABASE_URL,
  },
})
