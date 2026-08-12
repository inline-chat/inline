import { describe, expect, test } from "bun:test"
import { prompt } from "./prompt"

describe("Linear issue prompt", () => {
  test("binds task drafting to the selected message and provider-owned ids", () => {
    const value = prompt({
      primaryMessage: {
        author: "Mo",
        text: "@Arman please fix the Notion OAuth callback before Friday",
      },
      surroundingMessages: [
        { author: "Arman", text: "The debug app receives the production callback." },
      ],
      participants: [
        { displayName: "Mo", email: "mo@example.com" },
        { displayName: "Arman", email: "arman@example.com" },
      ],
      linearWorkspaceUsers: [
        { id: "linear-arman", name: "Arman", email: "arman@example.com" },
      ],
      labels: [
        { id: "label-bug", name: "Bug" },
      ],
    })

    expect(value).toContain("@Arman please fix the Notion OAuth callback before Friday")
    expect(value).toContain("The debug app receives the production callback.")
    expect(value).toContain("Arman <arman@example.com> (id=linear-arman)")
    expect(value).toContain("Bug (id=label-bug)")
    expect(value).toContain("Use only information supported by the provided context")
    expect(value).toContain("matching one of the ids in <linear_workspace_users>")
    expect(value).toContain("Choose 0–3 labelIds from the label list")
    expect(value).toContain("Return ONLY valid JSON matching the schema")
  })

  test("keeps optional provider context empty instead of inventing placeholders", () => {
    const value = prompt({
      primaryMessage: { author: "Mo", text: "Ship the fix" },
      surroundingMessages: [],
      participants: [],
      linearWorkspaceUsers: [],
      labels: [],
    })

    expect(value).toContain("<surrounding_messages>\n\n</surrounding_messages>")
    expect(value).toContain("<linear_workspace_users>\n\n</linear_workspace_users>")
    expect(value).toContain("<labels>\n\n</labels>")
    expect(value).toContain("or null if you can’t decide confidently")
  })
})
