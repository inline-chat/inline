#if os(macOS)
import AppKit
import Foundation
import InlineAvatarCore
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

  @Test("renders named and generic fallback avatars at the requested size")
  func rendersFallbackAvatars() throws {
    let namedPresentation = InlineAvatarPresentation.user(identity: .init(
      firstName: "Ada",
      lastName: "Lovelace",
      displayName: nil,
      email: "ada@example.com",
      username: nil,
      stableIdentifier: "user:1"
    ))
    let genericPresentation = InlineAvatarPresentation.user(identity: .init(
      firstName: nil,
      lastName: nil,
      displayName: nil,
      email: nil,
      username: nil,
      stableIdentifier: "user:2"
    ))

    let namedImage = try #require(MacNotificationAvatarRenderer.makeImage(
      presentation: namedPresentation,
      size: CGSize(width: 44, height: 44)
    ))
    let genericImage = try #require(MacNotificationAvatarRenderer.makeImage(
      presentation: genericPresentation,
      size: CGSize(width: 60, height: 60)
    ))

    #expect(namedImage.width == 44)
    #expect(namedImage.height == 44)
    #expect(genericImage.width == 60)
    #expect(genericImage.height == 60)

    let representation = NSBitmapImageRep(cgImage: namedImage)
    let pngData = try #require(representation.representation(using: .png, properties: [:]))
    #expect(!pngData.isEmpty)
  }

  @Test("only generates initials when no profile photo is configured")
  func initialsFallbackPolicy() {
    let missingPhoto = UserInfo(
      user: User(id: 1, email: nil, firstName: "Ada"),
      profilePhotos: nil
    )
    var unavailablePhotoUser = User(id: 2, email: nil, firstName: "Grace")
    unavailablePhotoUser.profileCdnUrl = "https://example.com/avatar.jpg"
    let unavailablePhoto = UserInfo(user: unavailablePhotoUser, profilePhotos: nil)

    #expect(MacNotificationAvatarPolicy.shouldGenerateInitials(for: missingPhoto))
    #expect(!MacNotificationAvatarPolicy.shouldGenerateInitials(for: unavailablePhoto))
    #expect(!MacNotificationAvatarPolicy.shouldGenerateInitials(for: nil))
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
