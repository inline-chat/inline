import { describe, expect, test } from "bun:test"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  chatAgentContext,
  normalizeAgentConfigurationCatalog,
  normalizeAgentThreadContext,
} from "@in/server/modules/agentConfiguration"

describe("Agent configuration contracts", () => {
  test("keeps typed catalog sections independently optional", () => {
    expect(normalizeAgentConfigurationCatalog({
      projects: {
        options: [{ id: " local ", label: " Local ", description: " This Mac " }],
        canSelectFolder: true,
      },
      models: undefined,
      reasoning: undefined,
    })).toEqual({
      projects: {
        options: [{ id: "local", label: "Local", description: "This Mac" }],
        canSelectFolder: true,
      },
      models: undefined,
      reasoning: undefined,
    })
  })

  test("rejects duplicate IDs and invalid model reasoning references", () => {
    expect(() => normalizeAgentConfigurationCatalog({
      projects: {
        options: [
          { id: "one", label: "One", description: undefined },
          { id: "one", label: "Again", description: undefined },
        ],
        canSelectFolder: undefined,
      },
      models: undefined,
      reasoning: undefined,
    })).toThrow(RealtimeRpcError)

    expect(() => normalizeAgentConfigurationCatalog({
      projects: undefined,
      models: {
        options: [{
          id: "model",
          label: "Model",
          description: undefined,
          reasoningEffortIds: ["missing"],
        }],
      },
      reasoning: { options: [] },
    })).toThrow(RealtimeRpcError)
  })

  test("represents provider defaults through absent selections", () => {
    expect(normalizeAgentThreadContext({
      botUserId: 42n,
      agentId: undefined,
      configuration: {
        projectId: undefined,
        modelId: undefined,
        reasoningEffortId: undefined,
      },
    })).toEqual({
      botUserId: 42n,
      agentId: undefined,
      configuration: undefined,
    })
  })

  test("fails closed when a persisted Chat context is malformed", () => {
    expect(() => chatAgentContext({ agentContext: Buffer.from([0xFF]) })).toThrow(RealtimeRpcError)
  })
})
