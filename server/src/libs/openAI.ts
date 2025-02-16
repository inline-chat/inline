import OpenAI from "openai"

export let openaiClient: OpenAI | undefined = undefined

if (process.env.OPENAI_API_KEY && process.env.OPENAI_BASE_URL) {
  openaiClient = new OpenAI({
    apiKey: process.env.OPENAI_API_KEY,
    baseURL: process.env.OPENAI_BASE_URL,
  })
}
