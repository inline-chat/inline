import OpenAI from "openai"

export let openaiClient: OpenAI | undefined = undefined

if (process.env.OPENAI_API_KEY) {
  openaiClient = new OpenAI({
    apiKey: process.env.OPENAI_API_KEY,
    baseURL: "https://api.openai.com/v1",
  })
}
