import Foundation
import Testing
@testable import InlineKit

@Suite("Notion task error messages")
struct NotionTaskErrorMessageTests {
  @Test("prefers propagated API descriptions")
  func prefersAPIErrorDescription() {
    let error = NotionTaskError.apiError(
      APIError.error(
        error: "BAD_REQUEST",
        errorCode: 400,
        description: "This Notion source needs to be reselected in Space Settings before tasks can be created."
      )
    )

    #expect(
      notionTaskUserFacingMessage(error: error)
        == "This Notion source needs to be reselected in Space Settings before tasks can be created."
    )
  }

  @Test("falls back for generic errors")
  func fallsBackForGenericErrors() {
    #expect(
      notionTaskUserFacingMessage(error: NSError(domain: "InlineTests", code: 1))
        == "Failed to create Notion task"
    )
  }
}
