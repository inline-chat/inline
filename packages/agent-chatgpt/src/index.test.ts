import { describe, expect, test } from "bun:test"
import {
  buildChatgptToolList,
  encodeChatgptProviderTool,
  encodeChatgptServerTool,
  isChatgptEncryptedReasoningError,
  type ChatgptServerTool,
} from "./index"

const params = {
  type: "object",
  additionalProperties: false,
  properties: {},
}

const readChat: ChatgptServerTool = {
  name: "read_chat",
  description: "Read chat history.",
  parameters: params,
}

describe("agent-chatgpt", () => {
  test("encodes built-in Responses tools", () => {
    expect(encodeChatgptProviderTool({ type: "web_search", returnTokenBudget: 2048 })).toEqual({
      type: "web_search",
      return_token_budget: 2048,
    })

    expect(
      encodeChatgptProviderTool({
        type: "image_generation",
        action: "auto",
        model: "chatgpt-image-latest",
        outputFormat: "png",
        outputCompression: 90,
        partialImages: 1,
      }),
    ).toEqual({
      type: "image_generation",
      action: "auto",
      model: "chatgpt-image-latest",
      output_format: "png",
      output_compression: 90,
      partial_images: 1,
    })

    expect(
      encodeChatgptProviderTool({
        type: "code_interpreter",
        container: { type: "auto", memoryLimit: "4g", fileIds: ["file_1"] },
      }),
    ).toEqual({
      type: "code_interpreter",
      container: { type: "auto", memory_limit: "4g", file_ids: ["file_1"] },
    })

    expect(
      encodeChatgptProviderTool({
        type: "mcp",
        serverLabel: "stripe",
        serverUrl: "https://mcp.stripe.com",
        requireApproval: "always",
      }),
    ).toEqual({
      type: "mcp",
      server_label: "stripe",
      server_url: "https://mcp.stripe.com",
      require_approval: "always",
    })
  })

  test("encodes server-hosted function tools", () => {
    expect(encodeChatgptServerTool(readChat, { strict: true })).toEqual({
      type: "function",
      name: "read_chat",
      description: "Read chat history.",
      parameters: params,
      strict: true,
    })
  })

  test("builds an omitted tool list when no tools are configured", () => {
    expect(buildChatgptToolList({})).toBeUndefined()
    expect(buildChatgptToolList({ providerTools: [{ type: "image_generation", action: "auto" }], serverTools: [readChat] })).toHaveLength(2)
  })

  test("detects encrypted reasoning replay errors", () => {
    expect(isChatgptEncryptedReasoningError({ code: "invalid_encrypted_content" })).toBe(true)
    expect(isChatgptEncryptedReasoningError(new Error("nope"))).toBe(false)
  })
})
