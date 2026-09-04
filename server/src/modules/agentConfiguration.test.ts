import { describe, expect, test } from "bun:test"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  agentContextSanitizationMetadata,
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

  test("discards malformed optional selections without rejecting the bot target", () => {
    expect(normalizeAgentThreadContext({
      botUserId: 42n,
      agentId: 0n,
      configuration: {
        projectId: " ",
        modelId: " model ",
        reasoningEffortId: "x".repeat(257),
      },
    })).toEqual({
      botUserId: 42n,
      agentId: undefined,
      configuration: {
        projectId: undefined,
        modelId: "model",
        reasoningEffortId: undefined,
      },
    })
  })

  test("builds bounded Sentry metadata without Agent IDs or configuration values", () => {
    const input = {
      botUserId: 42n,
      agentId: 7n,
      configuration: {
        projectId: "private-project",
        modelId: "private-model",
        reasoningEffortId: "private-reasoning",
      },
    }
    const sanitized = {
      botUserId: 42n,
      agentId: undefined,
      configuration: { modelId: "private-model" },
    }

    const metadata = agentContextSanitizationMetadata(
      "create_chat",
      input,
      sanitized,
      ["agent_unavailable", "project_unavailable", "reasoning_unsupported"],
    )

    expect(metadata).toEqual({
      event: "agent_context.sanitized",
      operation: "create_chat",
      reasonCodes: "agent_unavailable,project_unavailable,reasoning_unsupported",
      reasonCount: 3,
      discardedItemCount: 3,
      hadAgentId: true,
      hadConfiguration: true,
      hadProject: true,
      hadModel: true,
      hadReasoning: true,
      keptAgentId: false,
      keptConfiguration: true,
      keptProject: false,
      keptModel: true,
      keptReasoning: false,
    })
    const serialized = JSON.stringify(metadata)
    expect(serialized).not.toContain("private-project")
    expect(serialized).not.toContain("private-model")
    expect(serialized).not.toContain("private-reasoning")
    expect(serialized).not.toContain("\"42\"")
    expect(serialized).not.toContain("\"7\"")
  })

  test("fails closed when a persisted Chat context is malformed", () => {
    expect(() => chatAgentContext({ agentContext: Buffer.from([0xFF]) })).toThrow(RealtimeRpcError)
  })
})
