import AppKit
import InlineKit
import InlineUI
import SwiftUI

@MainActor
enum MenuIcon {
  nonisolated static let defaultSize: CGFloat = 18

  private static let maxCachedImages = 160
  private static var images: [Key: NSImage] = [:]

  static func image(for peer: ChatIcon.PeerType, size: CGFloat = defaultSize) -> NSImage? {
    let scheme = currentColorScheme
    let key = key(for: peer, size: size, colorScheme: scheme)

    if let image = images[key] {
      return image
    }

    let image = directImage(for: peer, size: size) ?? render(peer: peer, size: size, colorScheme: scheme)
    guard let image else { return nil }

    if images.count >= maxCachedImages {
      images.removeAll(keepingCapacity: true)
    }
    images[key] = image
    return image
  }

  static func image(for userInfo: UserInfo, size: CGFloat = defaultSize) -> NSImage? {
    image(for: .user(userInfo), size: size)
  }

  private static func directImage(for peer: ChatIcon.PeerType, size: CGFloat) -> NSImage? {
    guard case let .user(userInfo) = peer else {
      return nil
    }

    return localProfileImage(for: userInfo, size: size)
  }

  private static func localProfileImage(for userInfo: UserInfo, size: CGFloat) -> NSImage? {
    for url in profileImageUrls(for: userInfo) {
      guard FileManager.default.fileExists(atPath: url.path),
            let image = NSImage(contentsOf: url),
            image.size.width > 0,
            image.size.height > 0
      else {
        continue
      }

      return circularImage(from: image, size: size)
    }

    return nil
  }

  private static func profileImageUrls(for userInfo: UserInfo) -> [URL] {
    var urls: [URL] = []

    if let file = userInfo.profilePhoto?.first {
      if let localUrl = file.getLocalURL() {
        urls.append(localUrl)
      }
      if let localPath = file.localPath {
        urls.append(FileCache.getUrl(for: .photos, localPath: localPath))
      }
    }

    if let localUrl = userInfo.user.getLocalURL() {
      urls.append(localUrl)
    }
    if let localPath = userInfo.user.profileLocalPath {
      urls.append(FileCache.getUrl(for: .photos, localPath: localPath))
    }

    var seen = Set<String>()
    return urls.filter { url in
      let key = url.standardizedFileURL.path
      return seen.insert(key).inserted
    }
  }

  private static func circularImage(from image: NSImage, size: CGFloat) -> NSImage? {
    let targetSize = NSSize(width: size, height: size)
    let output = NSImage(size: targetSize)
    let targetRect = NSRect(origin: .zero, size: targetSize)
    let sourceRect = aspectFillSourceRect(imageSize: image.size)

    output.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSBezierPath(ovalIn: targetRect).addClip()
    image.draw(in: targetRect, from: sourceRect, operation: .copy, fraction: 1)
    output.unlockFocus()

    output.size = targetSize
    output.isTemplate = false
    return output
  }

  private static func aspectFillSourceRect(imageSize: NSSize) -> NSRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return .zero
    }

    let sourceAspect = imageSize.width / imageSize.height
    if sourceAspect > 1 {
      let width = imageSize.height
      return NSRect(
        x: (imageSize.width - width) / 2,
        y: 0,
        width: width,
        height: imageSize.height
      )
    }

    let height = imageSize.width
    return NSRect(
      x: 0,
      y: (imageSize.height - height) / 2,
      width: imageSize.width,
      height: height
    )
  }

  private static func render(peer: ChatIcon.PeerType, size: CGFloat, colorScheme: ColorScheme) -> NSImage? {
    let content = fallbackContent(for: peer, size: size)
      .frame(width: size, height: size)
      .environment(\.colorScheme, colorScheme)

    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(width: size, height: size)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

    guard let image = renderer.nsImage else {
      return nil
    }

    image.size = NSSize(width: size, height: size)
    image.isTemplate = false
    return image
  }

  @ViewBuilder
  private static func fallbackContent(for peer: ChatIcon.PeerType, size: CGFloat) -> some View {
    switch peer {
    case let .user(userInfo):
      userFallbackIcon(userInfo: userInfo, size: size)

    case let .savedMessage(user):
      InitialsCircle(
        name: user.firstName ?? user.username ?? "",
        size: size,
        symbol: "bookmark.fill"
      )

    case .chat:
      SidebarChatIcon(peer: peer, size: size)
    }
  }

  private static func userFallbackIcon(userInfo: UserInfo, size: CGFloat) -> InitialsCircle {
    let user = userInfo.user
    let name = UserAvatar.getNameForInitials(user: user)
    let symbol = user.firstName == nil && user.lastName == nil && user.email == nil && user.username == nil
      ? "person.fill"
      : nil

    return InitialsCircle(name: name, size: size, symbol: symbol)
  }

  private static var currentColorScheme: ColorScheme {
    switch NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      return .dark
    default:
      return .light
    }
  }

  private struct Key: Hashable {
    let id: Int64
    let kind: Kind
    let size: CGFloat
    let signature: String
    let colorScheme: ColorScheme

    enum Kind: Hashable {
      case chat
      case user
      case savedMessage
    }
  }

  private static func key(for peer: ChatIcon.PeerType, size: CGFloat, colorScheme: ColorScheme) -> Key {
    switch peer {
    case let .chat(chat):
      return Key(
        id: chat.id,
        kind: .chat,
        size: size,
        signature: [
          chat.title ?? "",
          chat.emoji ?? "",
          chat.isReplyThread ? "reply" : "thread",
        ].joined(separator: "|"),
        colorScheme: colorScheme
      )

    case let .user(userInfo):
      let user = userInfo.user
      return Key(
        id: user.id,
        kind: .user,
        size: size,
        signature: [
          user.firstName ?? "",
          user.lastName ?? "",
          user.username ?? "",
          user.email ?? "",
          userInfo.stableAvatarIdentity ?? "",
          profileImageSignature(for: userInfo),
        ].joined(separator: "|"),
        colorScheme: colorScheme
      )

    case let .savedMessage(user):
      return Key(
        id: user.id,
        kind: .savedMessage,
        size: size,
        signature: [
          user.firstName ?? "",
          user.username ?? "",
        ].joined(separator: "|"),
        colorScheme: colorScheme
      )
    }
  }

  private static func profileImageSignature(for userInfo: UserInfo) -> String {
    let urls = profileImageUrls(for: userInfo)
    let values = urls.map { url in
      let path = url.standardizedFileURL.path
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attrs[.modificationDate] as? Date
      else {
        return "missing:\(path)"
      }

      return "local:\(path):\(modified.timeIntervalSince1970)"
    }

    return values.joined(separator: "|")
  }
}
