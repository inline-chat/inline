import { describe, expect, it, spyOn } from "bun:test"
import { OauthModel } from "@in/server/db/models/oauth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { completeHostedLogin, getHostedLoginByCapability } from "@in/server/modules/auth/hostedLogin/service"
import { prepareAuthorizeRequest } from "@in/server/modules/oauth/httpHandlers"
import { loadSignupCompletedAlert } from "@in/server/modules/bot-events/alerts"
import { setupTestLifecycle, testUtils } from "./setup"

describe("signup attribution persistence", () => {
  setupTestLifecycle()

  it("preserves OAuth referral evidence through hosted login and encrypted session updates", async () => {
    const user = await testUtils.createUser("attribution@example.com")
    const client = await OauthModel.createClient({
      clientId: crypto.randomUUID(), clientName: "ChatGPT", redirectUris: ["https://chatgpt.com/callback"], nowMs: Date.now(),
    })
    const url = new URL("https://api.inline.chat/oauth/authorize")
    url.search = new URLSearchParams({
      response_type: "code", client_id: client.clientId, redirect_uri: client.redirectUris[0]!,
      state: "secret-state", code_challenge: "test-challenge", resource: "https://mcp.inline.chat",
      utm_source: "twitter", utm_campaign: "launch",
    }).toString()
    const response = await prepareAuthorizeRequest(new Request(url, { headers: { referer: "https://t.co/link?secret=hidden" } }))
    expect(response.status).toBe(303)
    const capability = new URL(response.headers.get("location")!).searchParams.get("capability")!
    const transaction = await getHostedLoginByCapability(capability)
    expect(transaction).toBeDefined()
    await completeHostedLogin({ transactionId: transaction!.id, account: { userId: user.id, method: "google" }, ip: "203.0.113.10" })
    const [session] = await SessionsModel.getValidSessionsByUserId(user.id)
    expect(session?.personalData.signupAttribution).toEqual({
      entryPoint: "oauth", oauthClient: "ChatGPT", authMethod: "google", referrerHost: "t.co",
      utmSource: "twitter", utmCampaign: "launch",
    })
    await SessionsModel.updateMetadata(session!.id, user.id, { deviceName: "Updated browser" })
    const alert = await loadSignupCompletedAlert(user, session!.id)
    expect(alert.split("\n").at(-1)).toBe(
      "client: web · via: ChatGPT OAuth · login: google · ref: t.co · utm: source=twitter, campaign=launch · ip: 203.0.113.10",
    )
    expect(alert).not.toContain("secret")
    expect(alert).not.toContain("hidden")
  })

  it("reads native platform metadata without borrowing another user's session", async () => {
    const user = await testUtils.createUser("native-attribution@example.com")
    const other = await testUtils.createUser("other-attribution@example.com")
    const { session } = await testUtils.createSessionForUser(user.id, { clientType: "macos", clientVersion: "0.7.14" })
    expect((await loadSignupCompletedAlert(user, session.id)).split("\n").at(-1))
      .toBe("client: macos 0.7.14 · ref: unknown")
    expect((await loadSignupCompletedAlert(other, session.id)).split("\n").at(-1))
      .toBe("client: unknown · ref: unknown")
  })

  it("still produces the signup alert when session lookup fails", async () => {
    const user = await testUtils.createUser("fallback-attribution@example.com")
    const lookup = spyOn(SessionsModel, "getById").mockRejectedValueOnce(new Error("unavailable"))
    try {
      const alert = await loadSignupCompletedAlert(user, 123)
      expect(alert).toContain("Signup completed:")
      expect(alert.split("\n").at(-1)).toBe("client: unknown · ref: unknown")
    } finally {
      lookup.mockRestore()
    }
  })
})
