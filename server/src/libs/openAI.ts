import OpenAI from "openai"
import { OPENAI_API_KEY } from "@in/server/env"

export let openaiClient: OpenAI | undefined = undefined

if (OPENAI_API_KEY) {
  openaiClient = new OpenAI({
    apiKey: OPENAI_API_KEY,
    baseURL: "https://api.openai.com/v1",
  })
}
