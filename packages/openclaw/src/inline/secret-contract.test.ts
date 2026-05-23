import { describe, expect, it } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { ResolverContext } from "openclaw/plugin-sdk/channel-secret-basic-runtime"
import {
  channelSecrets,
  collectRuntimeConfigAssignments,
  inlineSecrets,
  secretTargetRegistryEntries,
} from "./secret-contract"

function createContext(sourceConfig: OpenClawConfig): ResolverContext {
  return {
    sourceConfig,
    env: {},
    cache: {},
    warnings: [],
    warningKeys: new Set(),
    assignments: [],
  }
}

describe("inline/secret-contract", () => {
  it("declares Inline token SecretRef targets", () => {
    expect(secretTargetRegistryEntries.map((entry) => entry.id)).toEqual([
      "channels.inline.accounts.*.token",
      "channels.inline.token",
    ])
    expect(secretTargetRegistryEntries.every((entry) => entry.secretShape === "secret_input")).toBe(
      true,
    )
  })

  it("exports native setup-entry compatible channel secrets", () => {
    expect(channelSecrets).toBe(inlineSecrets)
    expect(channelSecrets.secretTargetRegistryEntries).toBe(secretTargetRegistryEntries)
    expect(channelSecrets.collectRuntimeConfigAssignments).toBe(collectRuntimeConfigAssignments)
  })

  it("collects active top-level and account token SecretRefs", () => {
    const cfg = {
      channels: {
        inline: {
          token: { source: "env", provider: "default", id: "INLINE_TOKEN" },
          accounts: {
            ops: {
              token: { source: "file", provider: "default", id: "inline/ops" },
            },
            inherited: {},
          },
        },
      },
    } satisfies OpenClawConfig
    const context = createContext(cfg)

    collectRuntimeConfigAssignments({
      config: cfg,
      defaults: undefined,
      context,
    })

    expect(context.assignments.map((assignment) => assignment.path)).toEqual([
      "channels.inline.token",
      "channels.inline.accounts.ops.token",
    ])
    expect(context.warnings).toEqual([])
  })

  it("warns instead of resolving token refs on disabled Inline accounts", () => {
    const cfg = {
      channels: {
        inline: {
          accounts: {
            ops: {
              enabled: false,
              token: { source: "env", provider: "default", id: "INLINE_TOKEN" },
            },
          },
        },
      },
    } satisfies OpenClawConfig
    const context = createContext(cfg)

    collectRuntimeConfigAssignments({
      config: cfg,
      defaults: undefined,
      context,
    })

    expect(context.assignments).toEqual([])
    expect(context.warnings).toEqual([
      expect.objectContaining({
        code: "SECRETS_REF_IGNORED_INACTIVE_SURFACE",
        path: "channels.inline.accounts.ops.token",
      }),
    ])
  })
})
