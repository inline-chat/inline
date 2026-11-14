import Foundation

/// Release, Debug and DevBuild install side by side on one device and share one keychain access
/// group, one app group and one vendor ID. Each can be signed into a different account or server,
/// so anything that belongs to one install (its signed-in account, push key, extension health
/// record, device ID) is named per install: otherwise a Debug build signed into another account
/// rewrites the account Release's notification extension checks, and every Release push is
/// withheld as "Open Inline to read it." Release keeps the historical names.
public enum InlineInstallNamespace {
  /// Empty for Release, otherwise the build's bundle suffix (`debug`, `devbuild`).
  public static let current: String = resolve(
    bundleIdentifier: Bundle.main.bundleIdentifier,
    isExtension: Bundle.main.bundlePath.hasSuffix(".appex")
  )

  static let releaseAppIdentifier = "chat.inline.InlineIOS"

  static func resolve(bundleIdentifier: String?, isExtension: Bool) -> String {
    guard var identifier = bundleIdentifier else { return "" }
    // An extension's identifier is its host app's identifier plus one component.
    if isExtension, let dot = identifier.lastIndex(of: ".") {
      identifier = String(identifier[..<dot])
    }
    guard identifier.hasPrefix(releaseAppIdentifier + ".") else { return "" }
    return String(identifier.dropFirst(releaseAppIdentifier.count + 1))
  }

  /// `name` for Release, `name.<namespace>` for other builds.
  public static func scoped(_ name: String, namespace: String = current) -> String {
    namespace.isEmpty ? name : "\(name).\(namespace)"
  }
}
