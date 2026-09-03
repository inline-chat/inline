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
        defaultProjectId: " local ",
      },
      models: undefined,
      reasoning: undefined,
    })).toEqual({
      projects: {
        options: [{ id: "local", label: "Local", description: "This Mac" }],
        canSelectFolder: true,
        defaultProjectId: "local",
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

  test("keeps only defaults that resolve to compatible choices", () => {
    expect(normalizeAgentConfigurationCatalog({
      projects: undefined,
      models: {
        options: [{
          id: " model ",
          label: " Model ",
          description: undefined,
          reasoningEffortIds: [" high "],
          defaultReasoningEffortId: " high ",
        }],
        defaultModelId: " model ",
      },
      reasoning: {
        options: [{ id: " high ", label: " High ", description: undefined }],
      },
    })).toEqual({
      projects: undefined,
      models: {
        options: [{
          id: "model",
          label: "Model",
          description: undefined,
          reasoningEffortIds: ["high"],
          defaultReasoningEffortId: "high",
        }],
        defaultModelId: "model",
      },
      reasoning: {
        options: [{ id: "high", label: "High", description: undefined }],
      },
    })

    expect(() => normalizeAgentConfigurationCatalog({
      projects: undefined,
      models: {
        options: [{
          id: "model",
          label: "Model",
          description: undefined,
          reasoningEffortIds: ["low"],
          defaultReasoningEffortId: "high",
        }],
        defaultModelId: "missing",
      },
      reasoning: {
        options: [
          { id: "low", label: "Low", description: undefined },
          { id: "high", label: "High", description: undefined },
        ],
      },
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
