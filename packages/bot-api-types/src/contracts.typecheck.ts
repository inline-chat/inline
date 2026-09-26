import type { BotApiEnvelope, BotTargetInput } from "./index.js"

const success: BotApiEnvelope<number> = { ok: true, result: 7 }
const failure: BotApiEnvelope<number> = { ok: false, error_code: 403, description: "denied" }
const peer: BotTargetInput = { chat_id: 42 }

// @ts-expect-error A success envelope requires its result.
const invalidSuccess: BotApiEnvelope<number> = { ok: true }
// @ts-expect-error A failure envelope requires an error code.
const invalidFailure: BotApiEnvelope<number> = { ok: false, description: "denied" }

void success
void failure
void peer
void invalidSuccess
void invalidFailure
