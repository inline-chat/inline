import { describe, expect, test } from "bun:test"

import { buildSteps, parseBetaGateArgs } from "./rich-text-beta-gate"

describe("rich text beta gate arguments", () => {
  test("defaults to preflight-only mode", () => {
    const options = parseBetaGateArgs([])

    expect(options.errors).toEqual([])
    expect(options.liveLogPaths).toEqual([])
    expect(options.requireOpenClawSignals).toBe(false)
  })

  test("default gate includes rich API and package type boundaries before macOS preflight", () => {
    const steps = buildSteps(parseBetaGateArgs([])).map((step) => step.name)

    expect(steps).toContain("server typecheck")
    expect(steps).toContain("markdown package typecheck")
    expect(steps).toContain("protocol package typecheck")
    expect(steps).toContain("SDK package typecheck")
    expect(steps).toContain("Bot API types package typecheck")
    expect(steps).toContain("Bot API package typecheck")
    expect(steps).toContain("OpenClaw package typecheck")
    expect(steps.at(-1)).toBe("macOS rich text testbook preflight")
  })

  test("collects server and OpenClaw live logs", () => {
    const options = parseBetaGateArgs([
      "--live-log",
      "../.tmp/rich-text-live-server.log",
      "--openclaw-live-log",
      "../.tmp/rich-text-live-openclaw.log",
      "--require-media-upload",
    ])

    expect(options.errors).toEqual([])
    expect(options.liveLogPaths).toEqual([
      "../.tmp/rich-text-live-server.log",
      "../.tmp/rich-text-live-openclaw.log",
    ])
    expect(options.requireMediaUpload).toBe(true)
    expect(options.requireOpenClawSignals).toBe(true)
  })

  test("deduplicates repeated combined live log paths while requiring OpenClaw evidence", () => {
    const options = parseBetaGateArgs([
      "--live-log",
      "../.tmp/rich-text-live-combined.log",
      "--openclaw-live-log",
      "../.tmp/rich-text-live-combined.log",
    ])

    expect(options.errors).toEqual([])
    expect(options.liveLogPaths).toEqual(["../.tmp/rich-text-live-combined.log"])
    expect(options.requireOpenClawSignals).toBe(true)
  })

  test("live log check runs after package and macOS gates", () => {
    const steps = buildSteps(
      parseBetaGateArgs([
        "--live-log",
        "../.tmp/rich-text-live-server.log",
        "--openclaw-live-log",
        "../.tmp/rich-text-live-openclaw.log",
      ]),
    ).map((step) => step.name)

    expect(steps.at(-2)).toBe("macOS rich text testbook preflight")
    expect(steps.at(-1)).toBe("strict rich text live log check")
  })

  test("reports missing live log paths", () => {
    const options = parseBetaGateArgs(["--live-log", "--require-openclaw-signals"])

    expect(options.errors).toContain("--live-log requires a path")
  })

  test("media upload requirement needs live logs", () => {
    const options = parseBetaGateArgs(["--require-media-upload"])

    expect(options.errors).toContain("--require-media-upload requires at least one --live-log or --openclaw-live-log")
  })

  test("reports unknown arguments", () => {
    const options = parseBetaGateArgs(["--unknown"])

    expect(options.errors).toEqual(["unknown argument: --unknown"])
  })
})
