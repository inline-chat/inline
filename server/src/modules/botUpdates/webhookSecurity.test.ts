import { describe, expect, it } from "bun:test"
import { validateWebhookUrl } from "./webhookSecurity"

describe("bot webhook URL validation", () => {
  it("rejects insecure and local targets before DNS", async () => {
    await expect(validateWebhookUrl("http://example.com/hook")).rejects.toThrow()
    await expect(validateWebhookUrl("https://localhost/hook")).rejects.toThrow()
    await expect(validateWebhookUrl("https://127.0.0.1/hook")).rejects.toThrow()
    await expect(validateWebhookUrl("https://[::1]/hook")).rejects.toThrow()
    await expect(validateWebhookUrl("https://user:pass@example.com/hook")).rejects.toThrow()
  })
})
