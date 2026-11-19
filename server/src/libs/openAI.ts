import OpenAI from "openai"
import { OPENAI_API_KEY } from "@in/server/env"

export let openaiClient: OpenAI | undefined = undefined

if (OPENAI_API_KEY) {
  openaiClient = new OpenAI({
    apiKey: OPENAI_API_KEY,
    baseURL: "https://api.openai.com/v1",
    // The SDK default is 10 minutes per attempt, far past the 40 s deploy
    // drain. Callers that need longer pass their own per-request timeout.
    timeout: 30_000,
  })
}
