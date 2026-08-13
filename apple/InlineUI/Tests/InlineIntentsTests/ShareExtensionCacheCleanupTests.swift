import Foundation
@testable import InlineIntents
import Testing

@Suite("Share extension cache cleanup")
struct ShareExtensionCacheCleanupTests {
  @Test("logout cleanup removes the current payload and generated avatars only")
  func removesRecipientPayloadAndGeneratedAvatars() throws {
    let fileManager = FileManager.default
    let containerURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let avatarDirectoryName = "IntentAvatars"
    let avatarDirectoryURL = containerURL
      .appendingPathComponent(avatarDirectoryName, isDirectory: true)
    let otherFlavorAvatarDirectoryURL = containerURL
      .appendingPathComponent("IntentAvatars_dev", isDirectory: true)
    try fileManager.createDirectory(at: avatarDirectoryURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: otherFlavorAvatarDirectoryURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: containerURL) }

    let payloadURL = containerURL.appendingPathComponent("SharedData.json")
    let otherFlavorPayloadURL = containerURL.appendingPathComponent("SharedData_dev.json")
    let generatedJPEGURL = avatarDirectoryURL.appendingPathComponent("user-42-profile.jpg")
    let generatedPNGURL = avatarDirectoryURL.appendingPathComponent("user-84-fallback.png")
    let unrelatedURL = avatarDirectoryURL.appendingPathComponent("keep.txt")
    let otherFlavorAvatarURL = otherFlavorAvatarDirectoryURL.appendingPathComponent("user-42-profile.jpg")
    for url in [
      payloadURL,
      otherFlavorPayloadURL,
      generatedJPEGURL,
      generatedPNGURL,
      unrelatedURL,
      otherFlavorAvatarURL,
    ] {
      try Data("test".utf8).write(to: url)
    }

    try ShareExtensionCacheCleanup.clear(
      containerURL: containerURL,
      payloadFileName: payloadURL.lastPathComponent,
      avatarDirectoryName: avatarDirectoryName,
      fileManager: fileManager
    )

    #expect(!fileManager.fileExists(atPath: payloadURL.path))
    #expect(!fileManager.fileExists(atPath: generatedJPEGURL.path))
    #expect(!fileManager.fileExists(atPath: generatedPNGURL.path))
    #expect(fileManager.fileExists(atPath: otherFlavorPayloadURL.path))
    #expect(fileManager.fileExists(atPath: unrelatedURL.path))
    #expect(fileManager.fileExists(atPath: otherFlavorAvatarURL.path))
    #expect(fileManager.fileExists(atPath: avatarDirectoryURL.path))
  }

  @Test("cleanup is idempotent when no share data exists")
  func isIdempotent() throws {
    let fileManager = FileManager.default
    let containerURL = fileManager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: containerURL) }

    try ShareExtensionCacheCleanup.clear(
      containerURL: containerURL,
      payloadFileName: "SharedData.json",
      avatarDirectoryName: "IntentAvatars",
      fileManager: fileManager
    )
    try ShareExtensionCacheCleanup.clear(
      containerURL: containerURL,
      payloadFileName: "SharedData.json",
      avatarDirectoryName: "IntentAvatars",
      fileManager: fileManager
    )
  }
}
