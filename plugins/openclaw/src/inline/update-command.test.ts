import { afterEach, describe, expect, it, vi } from "vitest"
import type { OpenClawPluginApi, PluginCommandContext } from "openclaw/plugin-sdk"
import {
  createInlineUpdateCommand,
  handleInlineUpdateCommand,
  INLINE_UPDATE_COMMAND_SPEC,
  listInlineUpdateCommandSpecs,
  redactInlineUpdateLog,
  runInlineOpenClawUpdate,
  sanitizeInlineUpdateEnvironment,
} from "./update-command"

const originalInlineToken = process.env.INLINE_TOKEN

afterEach(() => {
  if (originalInlineToken === undefined) delete process.env.INLINE_TOKEN
  else process.env.INLINE_TOKEN = originalInlineToken
  vi.restoreAllMocks()
})

function commandCtx(overrides: Partial<PluginCommandContext> = {}): PluginCommandContext {
  return {
    channel: "inline",
    channelId: "inline",
    isAuthorizedSender: true,
    senderIsOwner: true,
    commandBody: "/inline_update",
    args: "",
    requestConversationBinding: async () => ({ status: "error", message: "unused" }),
    detachConversationBinding: async () => ({ removed: false }),
    getCurrentConversationBinding: async () => null,
    ...overrides,
  }
}

function api() {
  return {
    logger: {
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    },
  } as unknown as OpenClawPluginApi
}

describe("inline/update-command", () => {
  it("publishes an Inline-native update command with progress copy", () => {
    expect(INLINE_UPDATE_COMMAND_SPEC).toMatchObject({
      name: "inline-update",
      nativeNames: { inline: "inline_update" },
      nativeProgressMessages: { inline: "Updating the Inline plugin…" },
      channels: ["inline"],
      acceptsArgs: false,
      requiredScopes: ["operator.admin"],
    })
    expect(listInlineUpdateCommandSpecs()).toEqual([{
      name: "inline_update",
      description: "Update the Inline OpenClaw plugin",
      acceptsArgs: false,
    }])
    expect(createInlineUpdateCommand(api()).name).toBe("inline-update")
  })

  it("requires an owner and rejects arguments before starting an update", async () => {
    const runner = vi.fn()
    await expect(
      handleInlineUpdateCommand(api(), commandCtx({ senderIsOwner: false }), { runner }),
    ).resolves.toEqual({ text: "Only an OpenClaw owner can update plugins." })
    await expect(
      handleInlineUpdateCommand(api(), commandCtx({ isAuthorizedSender: false }), { runner }),
    ).resolves.toEqual({ text: "Only an OpenClaw owner can update plugins." })
    await expect(
      handleInlineUpdateCommand(api(), commandCtx({ args: "now" }), { runner }),
    ).resolves.toEqual({ text: "Usage: /inline_update" })
    expect(runner).not.toHaveBeenCalled()
  })

  it("delegates to the canonical OpenClaw plugin updater without credential env vars", async () => {
    const runner = vi.fn(async () => ({
      exitCode: 0,
      stdout: "Updated inline -> 0.0.65",
      stderr: "",
    }))
    const result = await runInlineOpenClawUpdate({
      env: {
        OPENCLAW_CLI_PATH: "/opt/openclaw/openclaw.mjs",
        OPENCLAW_STATE_DIR: "/opt/data",
        INLINE_TOKEN: "inline-secret",
        NODE_AUTH_TOKEN: "npm-secret",
      },
      runner,
    })

    expect(result.exitCode).toBe(0)
    expect(runner).toHaveBeenCalledWith(expect.objectContaining({
      command: process.execPath,
      args: [
        "/opt/openclaw/openclaw.mjs",
        "plugins",
        "update",
        "inline",
        "--accept-capabilities",
      ],
      env: {
        OPENCLAW_CLI_PATH: "/opt/openclaw/openclaw.mjs",
        OPENCLAW_STATE_DIR: "/opt/data",
      },
      timeoutMs: 300_000,
      maxBuffer: 262_144,
    }))
  })

  it("falls back to the OpenClaw executable on PATH", async () => {
    const runner = vi.fn(async () => ({ exitCode: 0, stdout: "updated", stderr: "" }))

    await runInlineOpenClawUpdate({ env: { PATH: "/usr/bin" }, runner })

    expect(runner).toHaveBeenCalledWith(expect.objectContaining({
      command: "openclaw",
      args: ["plugins", "update", "inline", "--accept-capabilities"],
      env: { PATH: "/usr/bin" },
    }))
  })

  it("returns restart guidance after a successful update", async () => {
    const pluginApi = api()
    const runner = vi.fn(async () => ({ exitCode: 0, stdout: "updated", stderr: "" }))

    await expect(
      handleInlineUpdateCommand(pluginApi, commandCtx(), { runner }),
    ).resolves.toEqual({
      text: "Inline plugin update completed. Run /restart to load the installed version.",
    })
    expect(pluginApi.logger.info).toHaveBeenCalledWith(
      "[inline-update] OpenClaw plugin updater completed successfully",
    )
  })

  it("redacts and bounds failed updater diagnostics", async () => {
    process.env.INLINE_TOKEN = "must-not-reach-logs"
    const pluginApi = api()
    const runner = vi.fn(async () => ({
      exitCode: 1,
      stdout: "Bearer must-not-reach-logs",
      stderr: [
        "https://user:password@example.com/pkg?token=private-value",
        "Authorization: Basic encoded-private-value",
      ].join("\n"),
    }))

    await expect(
      handleInlineUpdateCommand(pluginApi, commandCtx(), { runner }),
    ).resolves.toEqual({
      text: "Inline plugin update failed. Details were written to OpenClaw logs under [inline-update].",
    })
    const log = String(vi.mocked(pluginApi.logger.error).mock.calls[0]?.[0])
    expect(log).toContain("[inline-update]")
    expect(log).toContain("[REDACTED]")
    expect(log).not.toContain("must-not-reach-logs")
    expect(log).not.toContain("user:password")
    expect(log).not.toContain("private-value")
    expect(log).not.toContain("encoded-private-value")
    const bounded = redactInlineUpdateLog("x\n".repeat(200) + "y".repeat(10_000))
    expect(bounded.startsWith("[earlier output truncated]\n")).toBe(true)
    expect(bounded.length).toBeLessThanOrEqual(8_030)
  })

  it("distinguishes a missing CLI and a timed-out updater", async () => {
    await expect(
      handleInlineUpdateCommand(api(), commandCtx(), {
        runner: async () => ({
          exitCode: null,
          stdout: "",
          stderr: "",
          errorCode: "ENOENT",
        }),
      }),
    ).resolves.toEqual({
      text: "Inline plugin update is unavailable because the OpenClaw CLI was not found.",
    })
    await expect(
      handleInlineUpdateCommand(api(), commandCtx(), {
        runner: async () => ({
          exitCode: null,
          stdout: "",
          stderr: "",
          timedOut: true,
        }),
      }),
    ).resolves.toEqual({
      text: "Inline plugin update timed out. Details were written to OpenClaw logs under [inline-update].",
    })
  })

  it("allows only one update at a time", async () => {
    let finish: ((value: { exitCode: number; stdout: string; stderr: string }) => void) | undefined
    const runner = vi.fn(async () =>
      await new Promise<{ exitCode: number; stdout: string; stderr: string }>((resolve) => {
        finish = resolve
      }))
    const first = handleInlineUpdateCommand(api(), commandCtx(), { runner })

    await expect(
      handleInlineUpdateCommand(api(), commandCtx(), { runner }),
    ).resolves.toEqual({ text: "An Inline plugin update is already running." })
    finish?.({ exitCode: 0, stdout: "updated", stderr: "" })
    await expect(first).resolves.toEqual({
      text: "Inline plugin update completed. Run /restart to load the installed version.",
    })
    expect(runner).toHaveBeenCalledTimes(1)
  })

  it("contains unexpected updater errors and releases the update lock", async () => {
    process.env.INLINE_TOKEN = "must-not-reach-logs"
    const pluginApi = api()
    const failedRunner = vi.fn(async () => {
      throw new Error("runner failed with must-not-reach-logs")
    })

    await expect(
      handleInlineUpdateCommand(pluginApi, commandCtx(), { runner: failedRunner }),
    ).resolves.toEqual({
      text: "Inline plugin update failed. Details were written to OpenClaw logs under [inline-update].",
    })
    const log = String(vi.mocked(pluginApi.logger.error).mock.calls[0]?.[0])
    expect(log).toContain("[inline-update]")
    expect(log).toContain("[REDACTED]")
    expect(log).not.toContain("must-not-reach-logs")

    await expect(
      handleInlineUpdateCommand(api(), commandCtx(), {
        runner: async () => ({ exitCode: 0, stdout: "updated", stderr: "" }),
      }),
    ).resolves.toEqual({
      text: "Inline plugin update completed. Run /restart to load the installed version.",
    })
  })

  it("removes generic credential names while preserving runtime routing", () => {
    expect(sanitizeInlineUpdateEnvironment({
      PATH: "/usr/bin",
      OPENCLAW_STATE_DIR: "/opt/data",
      INLINE_BOT_TOKEN: "secret",
      CUSTOM_PASSWORD: "secret",
      FOO_AUTHORIZATION: "secret",
    })).toEqual({
      PATH: "/usr/bin",
      OPENCLAW_STATE_DIR: "/opt/data",
    })
  })
})
