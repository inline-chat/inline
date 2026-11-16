import Foundation
import Testing
@testable import InlineKit

@Suite("Native upload staging scope")
struct NativeUploadStagingScopeTests {
  @Test func macOSStagingIsScopedToTheAppAndProfile() {
    let support = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
    let unnamed = FileNativeUploadStagingStore.defaultRoot(
      applicationSupportDirectory: support, bundleIdentifier: "chat.inline.InlineMac", userProfile: nil
    )
    let work = FileNativeUploadStagingStore.defaultRoot(
      applicationSupportDirectory: support, bundleIdentifier: "chat.inline.InlineMac", userProfile: "work"
    )
    #if os(macOS)
    #expect(unnamed.path == "/tmp/Application Support/chat.inline.InlineMac/NativeUploads/default")
    #expect(work.path == "/tmp/Application Support/chat.inline.InlineMac/NativeUploads/work")
    #expect(FileNativeUploadStagingStore.legacySharedRoot?.lastPathComponent == "NativeUploads")
    #else
    #expect(unnamed == work)
    #endif
  }

  @Test func removeAllEmptiesTheFolderAndLeavesItsSiblingsAlone() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("staging-scope-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("mine", isDirectory: true)
    let sibling = base.appendingPathComponent("other-profile", isDirectory: true)
    for folder in [root, sibling] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    for name in ["a.body", "a.json", "staging-1-x", "cancel-1.json"] {
      try Data("x".utf8).write(to: root.appendingPathComponent(name))
    }
    let kept = sibling.appendingPathComponent("b.body")
    try Data("x".utf8).write(to: kept)

    #expect(await FileNativeUploadStagingStore(root: root).removeAll() == 4)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: kept.path))
    // A missing folder is fine.
    #expect(await FileNativeUploadStagingStore(root: base.appendingPathComponent("none")).removeAll() == 0)
  }
}
