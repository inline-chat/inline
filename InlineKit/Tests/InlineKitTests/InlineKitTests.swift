import Foundation
import Testing

@testable import InlineKit

@Test func testApiResponse() async throws {
  // Write your test here and use APIs like `#expect(...)` to check expected conditions.
  let json = """
    {
        "ok": true,
        "result": {"userId": 123, "token": "123"}
    }
    """
  let response: APIResponse<VerifyCode> = try JSONDecoder().decode(
    APIResponse<VerifyCode>.self, from: json.data(using: .utf8)!)

  if case let .success(result) = response {
    #expect(result?.token == "123")
    #expect(result?.userId == 123)
  } else {
    #expect(Bool(false))
  }
}
