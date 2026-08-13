import { describe, expect, test } from "bun:test"
import {
  interpolateCampaignVariables,
  renderCampaign,
  validateCampaignBodyImages,
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

  test("renders hosted Markdown images responsively with alt text", async () => {
    const rendered = await renderCampaign({
      subject: "Image preview",
      bodyText: "![Inline conversation preview](https://inline.chat/conversation.png)",
      variables: {},
      visibleUnsubscribe: false,
    })

    expect(rendered.html).toContain('src="https://inline.chat/conversation.png"')
    expect(rendered.html).toContain('alt="Inline conversation preview"')
    expect(rendered.html).toContain("max-width:100%")
    expect(rendered.html).toContain("height:auto")
    expect(rendered.text).toContain("Inline conversation preview")
    expect(rendered.text).toContain("https://inline.chat/conversation.png")
  })

  test("requires supported HTTPS images with useful alt text", () => {
    expect(validateCampaignBodyImages("![Screenshot](http://inline.chat/a.png)"))
      .toBe("campaign_image_requires_https")
    expect(validateCampaignBodyImages("![](https://inline.chat/a.png)"))
      .toBe("campaign_image_alt_required")
    expect(validateCampaignBodyImages("![Screenshot][hero]"))
      .toBe("campaign_image_syntax_unsupported")
  })
})
