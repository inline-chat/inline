import { describe, expect, test } from "bun:test"
import { textPart } from "@inline-chat/agent-core"
import {
  buildCodexResponsesInputForTest,
  codexErrorMetadataForTest,
  extractMediaFromImageGenerationPartialEvent,
  extractMediaFromOutputItem,
} from "./codexTransport"

describe("codex transport media extraction", () => {
  test("extracts completed image generation bytes", () => {
    const png = Buffer.from("image-bytes")
    const [media] = extractMediaFromOutputItem({
      type: "image_generation_call",
      id: "img_1",
      status: "completed",
      result: png.toString("base64"),
    })

    expect(media).toMatchObject({
      kind: "image",
      name: "generated-image.png",
      mimeType: "image/png",
      providerFileId: "img_1",
      caption: "Generated image",
    })
    expect(Buffer.from(media!.bytes!)).toEqual(png)
  })

  test("extracts streamed image generation partial bytes as media fallback", () => {
    const bytes = Buffer.from("partial-image")
    const partial = extractMediaFromImageGenerationPartialEvent({
      type: "response.image_generation_call.partial_image",
      item_id: "img_partial",
      partial_image_index: 1,
      partial_image_b64: bytes.toString("base64"),
    })

    expect(partial?.itemId).toBe("img_partial")
    expect(partial?.media).toMatchObject({
      kind: "image",
      name: "generated-image-2.png",
      mimeType: "image/png",
      providerFileId: "img_partial",
      caption: "Generated image",
    })
    expect(Buffer.from(partial!.media.bytes!)).toEqual(bytes)
  })

  test("extracts code interpreter image urls for the output adapter", () => {
    expect(
      extractMediaFromOutputItem({
        type: "code_interpreter_call",
        id: "ci_1",
        container_id: "container_1",
        outputs: [
          { type: "logs", logs: "hello" },
          { type: "image", url: "https://example.com/output.png" },
        ],
      }),
    ).toEqual([
      {
        kind: "image",
        name: "code-output-2.png",
        mimeType: "image/png",
        signedUrl: "https://example.com/output.png",
        providerFileId: "ci_1",
        caption: "Code interpreter image output",
      },
    ])
  })
})

describe("codex transport logging metadata", () => {
  test("summarizes provider errors without including provider body contents", () => {
    const error = Object.assign(new Error("400 status code (no body)"), {
      status: 400,
      headers: { "x-request-id": "req_123" },
      body: { message: "do not log this body" },
      error: { code: "bad_request", message: "do not log this nested body" },
    })

    const metadata = codexErrorMetadataForTest(error)

    expect(metadata).toMatchObject({
      name: "Error",
      message: "400 status code (no body)",
      status: 400,
      code: "bad_request",
      requestId: "req_123",
      hasBody: true,
      bodyKeys: ["message"],
      errorKeys: ["code", "message"],
    })
    expect(JSON.stringify(metadata)).not.toContain("do not log")
  })
})

describe("codex transport input conversion", () => {
  test("uses output_text for assistant history and input_text for user history", () => {
    expect(
      buildCodexResponsesInputForTest([
        { role: "user", parts: [textPart("Mo: hello")] },
        { role: "assistant", parts: [textPart("hi there")] },
      ]),
    ).toEqual([
      { role: "user", content: [{ type: "input_text", text: "Mo: hello" }] },
      { role: "assistant", content: [{ type: "output_text", text: "hi there" }] },
    ])
  })

  test("strips replay reasoning ids because store=false cannot resolve them", () => {
    expect(
      buildCodexResponsesInputForTest([], [
        {
          type: "reasoning",
          id: "rs_1",
          encrypted_content: "sealed",
        },
      ]),
    ).toEqual([
      {
        type: "reasoning",
        encrypted_content: "sealed",
        summary: [],
      },
    ])
  })
})
