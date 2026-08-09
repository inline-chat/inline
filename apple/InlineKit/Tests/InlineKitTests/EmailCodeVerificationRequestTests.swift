import Foundation
@testable import InlineKit
import Testing

@Suite("Email verification transport privacy")
struct EmailCodeVerificationRequestTests {
  @Test("credentials are sent only in a POST JSON body")
  func credentialsStayOutOfURL() throws {
    let payload = EmailCodeVerificationPayload(
      email: "sentinel@example.invalid",
      code: "914207",
      challengeToken: "challenge-sentinel",
      inviteCode: "invite-sentinel",
      deviceId: "device-sentinel",
      clientType: "ios",
      clientVersion: "1179",
      osVersion: "26.6",
      deviceName: "iPhone",
      timezone: "Asia/Tehran"
    )

    let request = try ApiClient.makeEmailCodeVerificationRequest(
      payload: payload,
      baseURL: "https://api.inline.chat/v1"
    )
    let requestURL = try #require(request.url)

    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(requestURL.absoluteString == "https://api.inline.chat/v1/verifyEmailCode")
    #expect(requestURL.query == nil)

    let body = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(EmailCodeVerificationPayload.self, from: body)
    let bodyText = try #require(String(data: body, encoding: .utf8))
    #expect(decoded == payload)
    for secret in [payload.email, payload.code, payload.challengeToken, payload.inviteCode].compactMap({ $0 }) {
      #expect(!requestURL.absoluteString.contains(secret))
      #expect(bodyText.contains(secret))
    }
  }

  @Test("absent compatibility fields are omitted rather than serialized as null")
  func optionalFieldsAreOmitted() throws {
    let payload = EmailCodeVerificationPayload(
      email: "user@example.invalid",
      code: "123456",
      challengeToken: nil,
      inviteCode: nil,
      deviceId: "device",
      clientType: nil,
      clientVersion: nil,
      osVersion: nil,
      deviceName: nil,
      timezone: nil
    )

    let request = try ApiClient.makeEmailCodeVerificationRequest(
      payload: payload,
      baseURL: "https://example.invalid/v1"
    )
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(Set(object.keys) == ["email", "code", "deviceId"])
  }
}
