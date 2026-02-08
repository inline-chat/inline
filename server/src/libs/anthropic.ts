import Anthropic from "@anthropic-ai/sdk"
import { ANTHROPIC_API_KEY } from "@in/server/env"

export let anthropic: Anthropic | undefined = undefined

if (ANTHROPIC_API_KEY) {
  anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY })
}
