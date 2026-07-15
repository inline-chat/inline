#if os(macOS)
import Foundation
import Testing

@testable import InlineKit

@Suite("Mac notifications")
struct MacNotificationsTests {
  @Test("posts only from an app bundle")
  func postsOnlyFromAppBundle() {
    #expect(MacNotifications.canPostSystemNotifications(
      bundleURL: URL(fileURLWithPath: "/Applications/Inline.app")
    ))
    #expect(!MacNotifications.canPostSystemNotifications(
      bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/libexec/swift/pm")
    ))
  }
}
#endif
