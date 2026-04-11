import Foundation
import Testing

@testable import InlineKit

@Suite("UserDefaults shared suite")
struct UserDefaultsSuiteTests {
  @Test("devbuild gets its own shared suite")
  func devBuildSuiteName() {
    #expect(UserDefaults.sharedSuiteName(userProfile: "devbuild") == "2487AN8AL4.chat.inline.devbuild")
  }

  @Test("default shared suite remains unchanged")
  func defaultSuiteName() {
    #expect(UserDefaults.sharedSuiteName(userProfile: nil) == "2487AN8AL4.chat.inline")
  }
}
