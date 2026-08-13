import Foundation

public enum ShareExtensionCacheCleanup {
  /// Removes only Inline's recipient payload and generated avatar exports.
  /// The avatar directory is retained so cleanup cannot recursively remove unrelated data.
  public static func clear(
    containerURL: URL,
    payloadFileName: String,
    avatarDirectoryName: String,
    fileManager: FileManager = .default
  ) throws {
    let payloadURL = containerURL.appendingPathComponent(payloadFileName)
    if fileManager.fileExists(atPath: payloadURL.path) {
      try fileManager.removeItem(at: payloadURL)
    }

    let avatarDirectoryURL = containerURL.appendingPathComponent(avatarDirectoryName)
    guard fileManager.fileExists(atPath: avatarDirectoryURL.path) else { return }

    let directoryValues = try avatarDirectoryURL.resourceValues(forKeys: [
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ])
    guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
      return
    }

    let candidates = try fileManager.contentsOfDirectory(
      at: avatarDirectoryURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var firstError: (any Error)?
    for candidate in candidates where isGeneratedAvatar(candidate) {
      do {
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory != true else { continue }
        try fileManager.removeItem(at: candidate)
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError { throw firstError }
  }

  private static func isGeneratedAvatar(_ url: URL) -> Bool {
    guard url.lastPathComponent.hasPrefix("user-") else { return false }
    return switch url.pathExtension.lowercased() {
    case "jpg", "png": true
    default: false
    }
  }
}
