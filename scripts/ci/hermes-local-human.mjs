// Runs from the clean package consumer, so every SDK import uses its packed artifact.
import assert from "node:assert/strict"
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const client = new InlineSdkClient({
  token: process.env.INLINE_E2E_HUMAN_TOKEN,
  baseUrl: process.env.INLINE_E2E_BASE_URL,
})
try {
  await client.connect()
  const result = await client.sendMessage({
    userId: Number(process.env.INLINE_E2E_BOT_ID),
    text: "ci-real-hermes-inbound",
  })
  assert.ok(result.messageId, "human message was not persisted")
} finally {
  await client.close()
}
