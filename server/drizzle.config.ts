import { defineConfig } from "drizzle-kit"
const DATABASE_URL = process.env["DATABASE_URL"] as string

export default defineConfig({
  schema: "./src/db/schema/index.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: {
    url: DATABASE_URL,
  },
})
