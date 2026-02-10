import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

describe("guardrails", () => {
  test("user-bucket inserts into updates must go through UserBucketUpdates", () => {
    // Scan non-test server code for any direct inserts into `updates` using the user bucket.
    // This prevents future features from bypassing the seq allocator and reintroducing dup seq bugs.
    const here = path.dirname(fileURLToPath(import.meta.url))
    const srcRoot = path.resolve(here, "..", "..") // server/src
    const excluded = path.resolve(srcRoot, "modules", "updates", "userBucketUpdates.ts")

    const matcher = /insert\(\s*updates\s*\)\s*\.values\(\s*\{[\s\S]{0,2000}?\bbucket\s*:\s*UpdateBucket\.User\b/m

    const hits: string[] = []
    const walk = (dir: string) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name)

        if (entry.isDirectory()) {
          if (entry.name === "__tests__") continue
          walk(full)
          continue
        }

        if (!entry.isFile()) continue
        if (!full.endsWith(".ts")) continue
        if (full === excluded) continue

        // Fast prefilter.
        const content = readFileSync(full, "utf8")
        if (!content.includes("insert(updates)") && !content.includes("insert (updates)")) continue
        if (!content.includes("UpdateBucket.User")) continue

        if (matcher.test(content)) {
          hits.push(path.relative(srcRoot, full))
        }
      }
    }

    // Ensure srcRoot exists; otherwise the test should fail loudly.
    expect(statSync(srcRoot).isDirectory()).toBe(true)
    walk(srcRoot)

    expect(hits).toEqual([])
  })
})
