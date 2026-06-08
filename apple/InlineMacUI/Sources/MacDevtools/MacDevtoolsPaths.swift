import Foundation
import InlineConfig

enum MacDevtoolsPaths {
  private static let rootDirectoryName = "MacDevtools"
  private static let logFileName = "current.jsonl"

  static func directoryURL() throws -> URL {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = appSupport
      .appendingPathComponent(rootDirectoryName, isDirectory: true)
      .appendingPathComponent(profileDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func logFileURL() throws -> URL {
    try directoryURL().appendingPathComponent(logFileName, isDirectory: false)
  }

  static var profileName: String {
    ProjectConfig.userProfile ?? "default"
  }

  private static var profileDirectoryName: String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitized = profileName.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let value = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return value.isEmpty ? "default" : value
  }
}
