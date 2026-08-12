import { describe, expect, test } from "bun:test"
import { renderConnectorOAuthCompletionPage } from "./connectorOAuthCompletionPage"

describe("connector OAuth completion page", () => {
  test("renders a self-contained successful app handoff", () => {
    const html = renderConnectorOAuthCompletionPage({
      provider: "notion",
      appUrl: "inline-debug://integrations/notion?success=true&source=oauth",
      succeeded: true,
    })

    expect(html).toContain("Notion connected")
    expect(html).toContain("You can close this tab and continue in Inline.")
    expect(html).toContain("Open Inline")
    expect(html).toContain(
      "inline-debug://integrations/notion?success=true&amp;source=oauth",
    )
    expect(html).not.toContain("<script")
    expect(html).not.toContain("https://")
  })

  test("renders a provider-specific failure handoff", () => {
    const html = renderConnectorOAuthCompletionPage({
      provider: "linear",
      appUrl: "inline-dev://integrations/linear?success=false&error=callback_failed",
      succeeded: false,
    })

    expect(html).toContain("Couldn’t connect Linear")
    expect(html).toContain("Return to Inline to review the error and try again.")
  })
})
