import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import path from "node:path"
import { parse } from "yaml"

const root = path.resolve(import.meta.dir, "../..")
const read = (relative: string) => readFileSync(path.join(root, relative), "utf8")
const workflow = (name: string) => parse(read(`.github/workflows/${name}`)) as {
  on: Record<string, unknown>
  permissions: Record<string, string>
  jobs: Record<string, { runs_on?: string; steps?: Array<{ run?: string; env?: Record<string, string> }> }>
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
    expect(Object.keys(apple.jobs).sort()).toEqual(["changes", "contracts", "ios-app", "macos-app", "required", "swift-main", "swift-utilities"])
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

  it("retains ARM64 native CLI tests while the workspace owns AMD64 tests", () => {
    const cli = read(".github/workflows/cli-check.yml")
    expect(cli).toContain("dtolnay/rust-toolchain@1.96.0")
    expect(cli).toContain(". -> target")
    expect(cli).toContain("if: matrix.target == 'aarch64-unknown-linux-musl'")
    expect(cli).toContain("cargo test --locked --profile ci-test")
    expect(read(".github/workflows/integrations.yml")).toContain("cargo test --workspace --all-targets --locked --profile ci-test")
    expect(workflow("integrations.yml").jobs.cli).toBeUndefined()
  })

  it("does not expose publication workflows to pull requests", () => {
    for (const name of ["npm-publish.yml", "cli-release.yml", "server-deploy.yml", "macos-tip-nightly.yml", "ios-early-testers.yml"]) {
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

  it("gates automatic internal iOS releases with trusted main scripts", () => {
    const ios = workflow("ios-early-testers.yml")
    expect(ios.on.schedule).toBeDefined()
    expect(ios.on.workflow_run).toEqual({ workflows: ["CI", "Apple Validation", "Server Tests", "CodeQL", "CLI Build"], types: ["completed"], branches: ["main"] })
    expect(ios.permissions.contents).toBe("read")
    const source = read(".github/workflows/ios-early-testers.yml")
    expect(source).toContain("github.ref == 'refs/heads/main'")
    expect(source).toContain("ref: main")
    expect(source).toContain("scripts/ci/nightly-tip-gate.py select-green")
    expect(source).toContain("EXPECTED_SHA: ${{ steps.gate.outputs.sha }}")
    expect(source).not.toContain("download-artifact")
    expect(read("scripts/ci/ios-early-testers.mjs")).not.toContain("betaAppReviewSubmissions")
  })

  it("tests published Hermes compatibility regularly and gates the exact release artifact", () => {
    const scheduled = workflow("hermes-compatibility.yml")
    expect(scheduled.on.schedule).toBeDefined()
    expect(scheduled.on.workflow_dispatch).toBeDefined()
    expect(scheduled.permissions.contents).toBe("read")
    const monitor = read(".github/workflows/hermes-compatibility.yml")
    expect(monitor).toContain("host: [latest, main]")
    expect(monitor).toContain("check-hermes-admission.mjs --latest")
    expect(monitor).not.toContain("continue-on-error: true")
    const integration = read(".github/workflows/integrations.yml")
    expect(integration).toContain("host: ['v2026.9.14', 'v2026.9.21', latest, main]")
    expect(integration).not.toContain('pip" install "hermes-agent==')
    const publish = read(".github/workflows/npm-publish.yml")
    expect(publish).toContain('check-hermes-admission.mjs --artifact "$HERMES_ARTIFACT"')
    expect(publish.indexOf("Validate exact Hermes artifact stock compatibility and receive refusal")).toBeLessThan(
      publish.indexOf("HERMES_ARTIFACT_SHA256:"),
    )
  })

  it("qualifies receiving with the pinned core and gates publication on the exact CI artifact", () => {
    const integration = workflow("integrations.yml")
    const receiveSteps = integration.jobs["local-integration"]!.steps!
    const matchingInstall = receiveSteps.find((step) => step.run?.includes("install-hermes-host.sh"))!.run!
    expect(matchingInstall).toContain("inlineHermes.testedHermesRepository")
    expect(matchingInstall).toContain("inlineHermes.testedHermesCommit")
    expect(matchingInstall).toContain('"$host_sha" "$host_repository"')
    expect(matchingInstall).not.toContain(" latest")
    const receivingStep = receiveSteps.find((step) => step.run?.includes("scripts/ci/local-bot-flow.mjs"))!
    expect(receivingStep.env?.HERMES_PREPARED_HOME_ROOT).toBe("${{ steps.hermes-host.outputs.hermes-home-root }}")
    expect(receivingStep.env?.HERMES_PREPARED_RUNTIME_DIR).toBe("${{ steps.hermes-host.outputs.hermes-runtime-dir }}")
    expect(read("scripts/ci/hermes-local-flow.py")).toContain('assert adapter.durable_intake is True and adapter._durable_intake_available()')
    expect(read("scripts/ci/local-bot-flow.mjs")).toContain("assertHermesReceivingHost(hermesReceivingPin(installedHermesManifest), receivingHost)")
    const publish = workflow("npm-publish.yml")
    expect(publish.permissions.actions).toBe("read")
    const runs = publish.jobs.publish!.steps!.map((step) => step.run ?? "")
    const select = runs.findIndex((run) => run.includes("hermes-receiving-proof.mjs select-run"))
    const verify = runs.findIndex((run) => run.includes("hermes-receiving-proof.mjs verify"))
    const send = runs.findIndex((run) => run.includes("npm publish --ignore-scripts"))
    expect(select).toBeGreaterThan(-1)
    expect(verify).toBeGreaterThan(select)
    expect(send).toBeGreaterThan(verify)
    expect(read(".github/workflows/npm-publish.yml")).toContain("name: local-integration-receipts")
    expect(read(".github/workflows/npm-publish.yml")).toContain("run-id: ${{ steps.hermes-proof.outputs.run-id }}")
    expect(read("scripts/ci/check-hermes-admission.mjs")).toContain("unwired durable receive refusal passed (offline)")
  })

})
