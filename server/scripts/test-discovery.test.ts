import { describe, expect, test } from "bun:test"
import { resolve } from "node:path"
import { classifyTest, discoverTests } from "./test-discovery"

describe("test discovery", () => {
  test("assigns runner ownership from syntax instead of comments or naming guesses", () => {
    expect(classifyTest("src/newArea/behavior.test.ts", 'import { test } from "vitest"')).toBe("effect")
    expect(classifyTest("src/core/behavior.test.ts", '// from "vitest"\nimport { test } from "bun:test"')).toBe("bun")
    expect(classifyTest("src/a.test.ts", 'import type { TestAPI } from "vitest"; import { test } from "bun:test"')).toBe("bun")
    expect(classifyTest("src/a.effect.bun.test.ts", 'import { test } from "bun:test"')).toBe("effect-bun")
    expect(classifyTest("packages/url-preview/src/a.test.ts", 'import { test } from "bun:test"')).toBe("preview")
  })
  test("rejects ambiguous or unowned tests instead of silently skipping them", () => {
    expect(() => classifyTest("a.test.ts", 'import "bun:test"; import "vitest"')).toThrow("exactly one")
    expect(() => classifyTest("a.test.ts", 'console.log("test")')).toThrow("exactly one")
    expect(() => classifyTest("a.effect.bun.test.ts", 'import "vitest"')).toThrow("must import bun:test")
  })
  test("includes colocated database tests and every test exactly once", () => {
    const files = discoverTests(resolve(import.meta.dir, ".."))
    expect(new Set(files.map((file) => file.path)).size).toBe(files.length)
    expect(files.find((file) => file.path === "src/modules/integrations/oauthTokenLifecycle.integration.test.ts")?.usesDatabase).toBe(true)
    expect(files.find((file) => file.path === "src/utils/normalize.test.ts")?.usesDatabase).toBe(false)
    expect(files.find((file) => file.path === "src/core/http/realtimeV3Host.test.ts")?.lane).toBe("bun")
    expect(files.filter((file) => file.lane === "preview").length).toBeGreaterThan(0)
  })
})
