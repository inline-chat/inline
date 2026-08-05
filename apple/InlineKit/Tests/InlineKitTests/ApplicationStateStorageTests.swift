import Foundation
import Testing

@testable import InlineKit

@Suite("Application state storage")
struct ApplicationStateStorageTests {
  @Test("state directory is bundle scoped under Application Support")
  func bundleScopedDirectory() {
    let applicationSupport = URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)

    let directory = FileHelpers.applicationStateDirectory(
      applicationSupportDirectory: applicationSupport,
      bundleIdentifier: "chat.inline.InlineMac"
    )

    #expect(directory == applicationSupport
      .appendingPathComponent("chat.inline.InlineMac", isDirectory: true)
      .appendingPathComponent("State", isDirectory: true))
  }

  @Test("legacy Documents state moves to the internal destination")
  func migratesLegacyState() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let state = root.appendingPathComponent("State", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let legacyURL = documents.appendingPathComponent("navigation_state.json")
    let destinationURL = state.appendingPathComponent("navigation_state.json")
    try Data("saved-state".utf8).write(to: legacyURL)

    try FileHelpers.moveLegacyStateFile(
      from: legacyURL,
      to: destinationURL,
      fileManager: .default
    )

    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "saved-state")
  }

  @Test("an existing internal file remains authoritative")
  func preservesExistingState() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let documents = root.appendingPathComponent("Documents", isDirectory: true)
    let state = root.appendingPathComponent("State", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let legacyURL = documents.appendingPathComponent("transactions.json")
    let destinationURL = state.appendingPathComponent("transactions.json")
    try Data("legacy".utf8).write(to: legacyURL)
    try Data("current".utf8).write(to: destinationURL)

    try FileHelpers.moveLegacyStateFile(
      from: legacyURL,
      to: destinationURL,
      fileManager: .default
    )

    #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "current")
    #expect(FileManager.default.fileExists(atPath: legacyURL.path))
  }
}
