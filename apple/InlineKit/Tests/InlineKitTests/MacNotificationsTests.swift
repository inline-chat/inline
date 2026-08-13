#if os(macOS)
import Foundation
import InlineProtocol
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

  @Test("Document notifications use the file name")
  func documentNotificationsUseFileName() {
    let message = InlineProtocol.Message.with {
      $0.media.document.document.fileName = "Quarterly Report.pdf"
    }

    #expect(message.stringRepresentationWithEmoji == "📄 Quarterly Report.pdf")
    #expect(message.stringRepresentationPlain == "Quarterly Report.pdf")
  }
}
#endif
