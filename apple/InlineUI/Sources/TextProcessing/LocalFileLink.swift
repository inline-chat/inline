import Foundation
import UniformTypeIdentifiers

/// A message link pointing at a file on this machine, such as an agent's
/// `/Users/me/repo/main.rs:12`. Anyone can send one, so what a click does depends
/// only on the file's contents, never on its name or the app registered for it.
public struct LocalFileLink: Equatable, Sendable {
  public enum Disposition: Equatable, Sendable {
    /// Readable text. Always goes to the text editor, so a `.command` or `.webloc` is shown rather than run.
    case openInEditor
    /// Images, PDFs and media, which open in their default viewer.
    case openInViewer
    /// Everything else, including apps, packages and folders.
    case revealInFinder
  }

  public let path: String

  public init?(url: URL) {
    switch url.scheme?.lowercased() {
      case nil:
        guard url.host == nil else { return nil }
      case "file":
        guard url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true else { return nil }
      default:
        return nil
    }
    guard url.path.hasPrefix("/") else { return nil }
    path = Self.removingLineSuffix(url.path)
  }

  /// The real file behind the link, after symlinks, so the checks and the click act on the same file.
  public var fileURL: URL {
    URL(fileURLWithPath: path).resolvingSymlinksInPath()
  }

  /// Returns nil when the file is missing or this app is not allowed to see it.
  public func disposition() -> Disposition? {
    let url = fileURL
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]) else {
      return nil
    }
    // Reading a pipe or device could block forever.
    guard values.isRegularFile == true else { return .revealInFinder }
    if Self.isText(at: url) { return .openInEditor }
    if let type = values.contentType,
       [UTType.image, .pdf, .audiovisualContent].contains(where: { type.conforms(to: $0) })
    {
      return .openInViewer
    }
    return .revealInFinder
  }

  /// Agents cite `file.rs:12` and `file.rs:12:4`. Default apps can't jump to a line, so it's dropped.
  private static func removingLineSuffix(_ path: String) -> String {
    var result = Substring(path)
    for _ in 0 ..< 2 {
      guard let colon = result.lastIndex(of: ":"),
            Int(result[result.index(after: colon)...]) != nil
      else { break }
      result = result[..<colon]
    }
    return String(result)
  }

  private static func isText(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    // Reading an empty file can return nil.
    let head = (try? handle.read(upToCount: 4_096)) ?? Data()
    return !head.contains(0)
  }
}
