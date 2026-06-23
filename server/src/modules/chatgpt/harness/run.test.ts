import { describe, expect, test } from "bun:test"
import { RichDirection, type InputPeer, type RichMessage } from "@inline-chat/protocol/core"
import { chatgptRunTestHooks } from "./run"

const inputPeer: InputPeer = {
  type: { oneofKind: "chat", chat: { chatId: 42n } },
}

type StreamingDeps = Parameters<typeof chatgptRunTestHooks.writeStreamingVisibleText>[1]
type SendInput = Parameters<StreamingDeps["sendMessage"]>[0]
type EditInput = Parameters<StreamingDeps["editMessage"]>[0]
type DraftInput = Parameters<StreamingDeps["pushDraft"]>[0]
type SetOutputInput = Parameters<StreamingDeps["setOutputMessage"]>[0]
type MarkStreamingInput = Parameters<StreamingDeps["markStreaming"]>[0]

describe("ChatGPT run streaming flush policy", () => {
  test("creates one durable message for the first streamed rich draft", async () => {
    const calls = createCalls()

    const outputMsgGlobalId = await chatgptRunTestHooks.writeStreamingVisibleText(
      {
        inputPeer,
        actorUserId: 1,
        botUserId: 2,
        text: "hello",
        richText: richText("hello"),
        runId: "run-1",
      },
      createDeps(calls),
    )

    expect(outputMsgGlobalId).toBe(900n)
    expect(calls.send).toHaveLength(1)
    expect(calls.edit).toHaveLength(0)
    expect(calls.draft).toHaveLength(1)
    expect(calls.send[0]?.allowThinking).toBe(true)
    expect(calls.send[0]?.resolveRichMedia).toBe(false)
    expect(calls.send[0]?.richText?.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph"])
    expect(calls.draft[0]?.messageId).toBe(10n)
    expect(calls.draft[0]?.richText.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph"])
    expect(calls.setOutput).toEqual([{ runId: "run-1", outputMsgGlobalId: 900n }])
    expect(calls.markStreaming).toEqual([{ runId: "run-1", visibleTextLength: 5 }])
  })

  test("updates only the ephemeral rich draft after the durable message exists", async () => {
    const calls = createCalls()

    const outputMsgGlobalId = await chatgptRunTestHooks.writeStreamingVisibleText(
      {
        inputPeer,
        actorUserId: 1,
        botUserId: 2,
        outputMsgGlobalId: 900n,
        text: "hello again",
        richText: richText("hello again"),
        runId: "run-1",
      },
      createDeps(calls),
    )

    expect(outputMsgGlobalId).toBe(900n)
    expect(calls.send).toHaveLength(0)
    expect(calls.edit).toHaveLength(0)
    expect(calls.draft).toHaveLength(1)
    expect(calls.draft[0]?.messageId).toBeUndefined()
    expect(calls.draft[0]?.richText.blocks.map((block) => block.block.oneofKind)).toEqual(["thinking", "paragraph"])
    expect(calls.setOutput).toHaveLength(0)
    expect(calls.markStreaming).toEqual([{ runId: "run-1", visibleTextLength: 11 }])
  })
})

function createCalls(): {
  send: SendInput[]
  edit: EditInput[]
  draft: DraftInput[]
  setOutput: SetOutputInput[]
  markStreaming: MarkStreamingInput[]
} {
  return {
    send: [],
    edit: [],
    draft: [],
    setOutput: [],
    markStreaming: [],
  }
}

function createDeps(calls: ReturnType<typeof createCalls>): Parameters<
  typeof chatgptRunTestHooks.writeStreamingVisibleText
>[1] {
  return {
    sendMessage: async (input) => {
      calls.send.push(input)
      return { globalId: 900n, messageId: 10 }
    },
    editMessage: async (input) => {
      calls.edit.push(input)
    },
    pushDraft: async (input) => {
      calls.draft.push(input)
    },
    setOutputMessage: async (input) => {
      calls.setOutput.push(input)
    },
    markStreaming: async (input) => {
      calls.markStreaming.push(input)
    },
  }
}

function richText(text: string): RichMessage {
  return {
    version: 1,
    direction: RichDirection.DIRECTION_AUTO,
    fallbackText: text,
    blocks: [
      {
        blockId: "thinking",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "thinking",
          thinking: {
            initiallyCollapsed: true,
            blocks: [],
          },
        },
      },
      {
        blockId: "visible",
        direction: RichDirection.DIRECTION_AUTO,
        block: {
          oneofKind: "paragraph",
          paragraph: {
            text: [{ text, children: [], styles: [] }],
          },
        },
      },
    ],
  }
}
