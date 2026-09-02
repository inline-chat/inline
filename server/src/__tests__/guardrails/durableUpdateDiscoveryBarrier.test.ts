import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const durableInsertPositions = (source: string): number[] => {
  const targets: string[] = []
  const imports = /import\s+(?:\*\s+as\s+([\w$]+)|\{([^}]+)\})\s+from\s+["'][^"']*db\/schema(?:\/updates)?["']/g
  for (const match of source.matchAll(imports)) {
    if (match[1]) targets.push(`${escapeRegex(match[1])}\\s*\\.\\s*updates`)
    for (const binding of match[2]?.split(",") ?? []) {
      const update = /^\s*updates(?:\s+as\s+([\w$]+))?\s*$/.exec(binding)
      if (update) targets.push(escapeRegex(update[1] ?? "updates"))
    }
  }
  const positions: number[] = []
  if (targets.length > 0) {
    const insert = new RegExp(`\\.\\s*insert\\s*\\(\\s*(?:${targets.join("|")})\\s*\\)`, "g")
    for (const match of source.matchAll(insert)) positions.push(match.index)
  }
  for (const match of source.matchAll(/\binsert\s+into\s+(?:public\.)?"?updates"?\b/gi)) positions.push(match.index)
  return positions
}

const escapeRegex = (value: string): string => value.replaceAll(/[.*+?^${}()|[\]\\]/g, "\\$&")

describe("durable update discovery guardrails", () => {
  test("the guard recognizes aliased, namespaced, and raw SQL inserts", () => {
    expect(durableInsertPositions('import { updates as journal } from "@in/server/db/schema"; tx.insert(journal)')).toHaveLength(1)
    expect(durableInsertPositions('import * as schema from "@in/server/db/schema"; tx.insert(schema.updates)')).toHaveLength(1)
    expect(durableInsertPositions('tx.execute(sql`insert into updates (seq) values (1)`)')).toHaveLength(1)
    expect(durableInsertPositions('import { users } from "@in/server/db/schema"; tx.insert(users)')).toHaveLength(0)
  })

  test("production updates-table inserts use the fenced canonical owners", () => {
    const here = path.dirname(fileURLToPath(import.meta.url))
    const srcRoot = path.resolve(here, "..", "..")
    const expectedOwners = new Set([
      "db/models/updates.ts",
      "modules/updates/userBucketUpdates.ts",
    ])
    const writerFenceCall = /await\s+acquireUpdateDiscoveryWriterFence\(\s*tx\s*\)/m
    const owners: string[] = []

    const walk = (dir: string) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name)
        if (entry.isDirectory()) {
          if (entry.name !== "__tests__") walk(full)
          continue
        }
        if (!entry.isFile() || !full.endsWith(".ts") || /\.(test|spec)\.ts$/.test(full)) continue

        const source = readFileSync(full, "utf8")
        const insertPositions = durableInsertPositions(source)
        if (insertPositions.length === 0) continue

        const relative = path.relative(srcRoot, full)
        owners.push(relative)
        expect(expectedOwners.has(relative)).toBe(true)
        expect(source).toMatch(writerFenceCall)
        expect(source.search(writerFenceCall)).toBeLessThan(
          Math.min(...insertPositions),
        )
      }
    }

    expect(statSync(srcRoot).isDirectory()).toBe(true)
    walk(srcRoot)
    expect(new Set(owners)).toEqual(expectedOwners)
  })
})
