import Foundation
import Testing
@testable import TextProcessing

@Suite("LocalFileLink")
struct LocalFileLinkTests {
  @Test("Local paths are recognized and lose their line suffix", arguments: [
    ("/Users/me/repo/runtime.rs", "/Users/me/repo/runtime.rs"),
    ("/Users/me/repo/runtime.rs:1762", "/Users/me/repo/runtime.rs"),
    ("/Users/me/repo/runtime.rs:1762:8", "/Users/me/repo/runtime.rs"),
    ("/Users/me/repo/runtime.rs#L1762", "/Users/me/repo/runtime.rs"),
    ("/Users/me/my%20repo/a.md", "/Users/me/my repo/a.md"),
    ("file:///Users/me/repo/runtime.rs:12", "/Users/me/repo/runtime.rs"),
    ("file://localhost/Users/me/a.md", "/Users/me/a.md"),
  ])
  func recognized(link: String, path: String) throws {
    let url = try #require(URL(string: link))
    #expect(LocalFileLink(url: url)?.path == path)
  }

  @Test("Other links are left alone", arguments: [
    "https://inline.chat/a.md",
    "inline://chat/1",
    "file://server/share/a.md",
    "//server/share/a.md",
    "src/runtime.rs",
  ])
  func ignored(link: String) throws {
    let url = try #require(URL(string: link))
    #expect(LocalFileLink(url: url) == nil)
  }

  @Test("What a click does depends on the file's contents")
  func disposition() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func link(_ name: String, _ contents: Data) throws -> LocalFileLink {
      let url = directory.appendingPathComponent(name)
      try contents.write(to: url)
      return try #require(LocalFileLink(url: url))
    }
    let text = Data("#!/bin/sh\necho hi\n".utf8)
    let binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00])

    #expect(try link("main.rs", text).disposition() == .openInEditor)
    #expect(try link("evil.command", text).disposition() == .openInEditor)
    #expect(try link("evil.webloc", text).disposition() == .openInEditor)
    #expect(try link("empty.md", Data()).disposition() == .openInEditor)
    #expect(try link("photo.png", binary).disposition() == .openInViewer)
    #expect(try link("report.pdf", binary).disposition() == .openInViewer)
    #expect(try link("tool", binary).disposition() == .revealInFinder)
    #expect(try link("setup.pkg", binary).disposition() == .revealInFinder)

    let app = directory.appendingPathComponent("Evil.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(LocalFileLink(url: app)?.disposition() == .revealInFinder)

    let alias = directory.appendingPathComponent("notes.md")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
    #expect(LocalFileLink(url: alias)?.disposition() == .revealInFinder)

    let missing = directory.appendingPathComponent("missing.md")
    #expect(LocalFileLink(url: missing)?.disposition() == nil)
  }
}
