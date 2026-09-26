import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import path from "node:path"
import { parse } from "yaml"

const root = path.resolve(import.meta.dir, "../..")
const read = (relative: string) => readFileSync(path.join(root, relative), "utf8")
const workflow = (name: string) => parse(read(`.github/workflows/${name}`)) as {
  on: Record<string, unknown>
  permissions: Record<string, string>
  jobs: Record<string, { runs_on?: string; steps?: Array<{ run?: string }> }>
}

describe("public CI contracts", () => {
  it("pins Bun and Rust to the repository toolchain policy", () => {
    const bun = JSON.parse(read("package.json")).packageManager
    expect(bun).toBe("bun@1.4.0")
    expect(read("rust-toolchain.toml")).toContain('channel = "1.96.0"')
    for (const name of ["integrations.yml", "apple-validation.yml"]) {
      const source = read(`.github/workflows/${name}`)
      for (const match of source.matchAll(/bun-version:\s*['"]?([^\s'"#]+)/g)) {
        expect(match[1], name).toBe("1.4.0")
      }
    }
  })

  it("keeps integration, server, and Apple PR jobs read-only", () => {
    for (const name of ["integrations.yml", "apple-validation.yml", "server-test.yml"]) {
      const parsed = workflow(name)
      expect(parsed.on.pull_request, name).toBeDefined()
      expect(parsed.permissions.contents, name).toBe("read")
      expect(parsed.permissions["id-token"], name).toBeUndefined()
      expect((parsed.on.pull_request as Record<string, unknown> | undefined)?.paths, name).toBeUndefined()
    }
  })

  it("keeps all selected package and app gates visible", () => {
    const apple = workflow("apple-validation.yml")
    expect(Object.keys(apple.jobs).sort()).toEqual(["contracts", "ios-app", "macos-app", "swift-main", "swift-utilities"])
    const source = read(".github/workflows/apple-validation.yml")
    for (const pkg of ["InlineKit", "InlineUI", "InlineIOSUI", "InlineMacUI", "InlineRealtimeCore",
      "InlineMacSidebarModel", "InlineThumbnailing", "InlineSyntaxHighlighting", "InlineMacScripting",
      "InlineMath", "MemojiKit", "InlineDevCompanion"]) {
      expect(source, pkg).toContain(pkg)
    }
    expect(source).not.toContain("platform=iOS Simulator")
    const integrations = workflow("integrations.yml")
    for (const job of ["rust-workspace", "shared-packages", "candidate-packages", "packed-consumers", "workflow-and-release-contracts"]) {
      expect(integrations.jobs[job], job).toBeDefined()
    }
  })

  it("does not expose publication workflows to pull requests", () => {
    for (const name of ["npm-publish.yml", "cli-release.yml", "server-deploy.yml", "macos-tip-nightly.yml"]) {
      expect(workflow(name).on.pull_request, name).toBeUndefined()
    }
  })

  it("limits the nightly tip release to a green main selection", () => {
    const tip = workflow("macos-tip-nightly.yml")
    expect(tip.on.schedule).toBeDefined()
    expect(tip.on.workflow_dispatch).toBeDefined()
    const source = read(".github/workflows/macos-tip-nightly.yml")
    expect(source).toContain("github.ref == 'refs/heads/main'")
    expect(source).toContain("scripts/ci/nightly-tip-gate.py select")
    expect(source).toContain("ref: ${{ needs.select.outputs.sha }}")
    expect(source).toContain("INLINE_NIGHTLY_MAIN_SHA: ${{ needs.select.outputs.sha }}")
  })
})
