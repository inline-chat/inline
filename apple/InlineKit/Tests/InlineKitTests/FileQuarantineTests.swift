#if os(macOS)
import CoreServices
import Foundation
@testable import InlineKit
import Testing

@Suite("Downloaded file quarantine")
struct FileQuarantineTests {
  @Test("Unsandboxed downloads are quarantined, and copies keep the attribute")
  func marksDownloadedFile() throws {
    try #require(FileQuarantine.isNeeded, "test process is unsandboxed")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FileQuarantineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("report.pdf")
    try Data("pdf".utf8).write(to: file)
    #expect(try quarantineAgent(file) == nil)

    FileQuarantine.markDownloaded(file)
    #expect(try quarantineAgent(file) == "Inline")

    let copy = directory.appendingPathComponent("report copy.pdf")
    try FileManager.default.copyItem(at: file, to: copy)
    #expect(try quarantineAgent(copy) == "Inline")
  }

  private func quarantineAgent(_ url: URL) throws -> String? {
    var url = url
    url.removeAllCachedResourceValues()
    let properties = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    return properties?[kLSQuarantineAgentNameKey as String] as? String
  }
}
#endif
