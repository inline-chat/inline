import { describe, expect, test } from "bun:test"
import { listInternalAgentRegistrations, resolveInternalAgentAlias } from "./aliases"

describe("internal agent aliases", () => {
  test("resolves the ChatGPT official bot aliases", () => {
    expect(resolveInternalAgentAlias("@chat")?.agentKey).toBe("chatgpt")
    expect(resolveInternalAgentAlias("chatgpt")?.agentKey).toBe("chatgpt")
    expect(resolveInternalAgentAlias("GPT")?.agentKey).toBe("chatgpt")
  })

  test("keeps aliases in the registry object", () => {
    const registrations = listInternalAgentRegistrations()
    expect(registrations).toHaveLength(1)
    expect(registrations[0]).toMatchObject({
      agentKey: "chatgpt",
      botUsername: "chatgpt",
      displayName: "ChatGPT",
      connectionProvider: "openai_codex",
      official: true,
      aliases: ["chat", "chatgpt", "gpt"],
      commands: [
        {
          command: "stop",
          description: "Stop the current ChatGPT run",
          sortOrder: 0,
        },
      ],
      profilePhotoAsset: {
        fileName: "openai-black-monoblossom-white.png",
        mimeType: "image/png",
      },
    })
  })
})
