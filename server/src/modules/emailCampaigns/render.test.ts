import { describe, expect, test } from "bun:test"
import {
  interpolateCampaignVariables,
  renderCampaign,
} from "./render"

describe("campaign email rendering", () => {
  test("supports current variables and Noor's legacy name token", () => {
    expect(interpolateCampaignVariables(
      "Hi {{name}} / {{ first_name }} / <name> / {{email}}",
      { name: "Ada", email: "ada@example.com" },
    )).toBe("Hi Ada / Ada / Ada / ada@example.com")
  })

  test("uses a friendly name fallback", () => {
    expect(interpolateCampaignVariables("Hi {{name}}", {})).toBe("Hi there")
  })

  test("renders Markdown while preventing raw HTML injection", async () => {
    const rendered = await renderCampaign({
      subject: "Hello {{name}}",
      bodyText: "**Welcome**, {{name}}.\n\n<script>alert('no')</script>",
      variables: { name: "Ada", email: "ada@example.com" },
      unsubscribeUrl: "https://example.com/unsubscribe",
      visibleUnsubscribe: true,
    })

    expect(rendered.subject).toBe("Hello Ada")
    expect(rendered.html).toContain(">Welcome</strong>")
    expect(rendered.html).not.toContain("<script>")
    expect(rendered.html).toContain("&lt;script&gt;")
    expect(rendered.text).toContain("Welcome, Ada")
    expect(rendered.text).toContain("Unsubscribe")
  })
})
