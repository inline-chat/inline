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

  it("rejects literal private, NAT64, IPv4-compatible and other non-public IPv6 targets", async () => {
    for (const host of ["[64:ff9b::a9fe:a9fe]", "[::7f00:1]", "[::ffff:7f00:1]", "[fdaa::1]", "[2002:7f00:1::]", "169.254.169.254", "100.64.0.1"]) {
      await expect(validateWebhookUrl(`https://${host}/hook`)).rejects.toThrow()
    }
  })
})
