import Foundation
import Testing
import ZIPFoundation

@testable import InlineKit

@Suite("Folder ZIP attachments")
struct FolderArchiveTests {
  #if os(macOS)
  @Test("ZIP round-trip preserves nested files, Unicode names, and empty directories")
  func roundTrip() throws {
    let root = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("پوشه photos.png", isDirectory: true)
    let nested = folder.appendingPathComponent("nested/empty", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let contents = Data([0, 1, 2, 255])
    try contents.write(to: folder.appendingPathComponent("nested/فایل.bin"))

    let archive = try #require(try FolderArchive.createIfDirectory(at: folder))
    defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
    #expect(archive.lastPathComponent == "پوشه photos.png.zip")
    let output = root.appendingPathComponent("unpacked", isDirectory: true)
    try unzip(archive, into: output)
    let restored = output.appendingPathComponent(folder.lastPathComponent)
    #expect(try Data(contentsOf: restored.appendingPathComponent("nested/فایل.bin")) == contents)
    #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("nested/empty").path))
    #expect(try Data(contentsOf: folder.appendingPathComponent("nested/فایل.bin")) == contents)
  }

  #endif

  @Test("empty folders still produce valid ZIPs")
  func emptyFolder() throws {
    let folder = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let archive = try #require(try FolderArchive.createIfDirectory(at: folder))
    defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: archive).prefix(2) == Data([0x50, 0x4b]))
    let zip = try Archive(url: archive, accessMode: .read)
    let entry = try #require(zip[folder.lastPathComponent + "/"])
    #expect(entry.type == .directory)
    #expect(Array(zip).count == 1)
  }

  @Test("ordinary files do not get archived")
  func ordinaryFile() throws {
    let root = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("document.txt")
    try Data("hello".utf8).write(to: file)
    #expect(try FolderArchive.createIfDirectory(at: file) == nil)
  }

  @Test("missing sources report an error")
  func missingSource() throws {
    let root = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) {
      try FolderArchive.createIfDirectory(at: root.appendingPathComponent("missing"))
    }
  }

  @Test("folder symlinks are zipped with the selected name")
  func folderSymlink() throws {
    let root = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("contents".utf8).write(to: source.appendingPathComponent("file.txt"))
    let link = root.appendingPathComponent("selected")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let archive = try #require(try FolderArchive.createIfDirectory(at: link))
    defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
    #expect(archive.lastPathComponent == "selected.zip")
    let zip = try Archive(url: archive, accessMode: .read)
    #expect(zip["selected/"]?.type == .directory)
    #expect(zip["selected/file.txt"]?.type == .file)
  }

  @Test("nested symlinks are preserved without following external, broken, or cyclic targets")
  func nestedSymlinks() throws {
    let root = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub/empty"), withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: folder.appendingPathComponent("file.txt"))
    try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("must not be included".utf8).write(to: outside.appendingPathComponent("private.txt"))
    let links = [
      "file-link": "file.txt",
      "directory-link": "sub",
      "absolute-link": folder.appendingPathComponent("file.txt").path,
      "external-link": outside.path,
      "broken-link": "missing",
      "cycle-link": ".",
    ]
    for (name, target) in links {
      try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(name).path, withDestinationPath: target)
    }

    let archive = try #require(try FolderArchive.createIfDirectory(at: folder))
    defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
    let zip = try Archive(url: archive, accessMode: .read)
    let expectedPaths = Set(["project/", "project/sub/", "project/sub/empty/", "project/file.txt", "project/.hidden"])
      .union(links.keys.map { "project/" + $0 })
    #expect(Set(zip.map(\.path)) == expectedPaths)
    for (name, target) in links {
      let entry = try #require(zip["project/" + name])
      #expect(entry.type == .symlink)
      var contents = Data()
      _ = try zip.extract(entry) { contents.append($0) }
      #expect(String(data: contents, encoding: .utf8) == target)
    }
    #expect(try Data(contentsOf: outside.appendingPathComponent("private.txt")) == Data("must not be included".utf8))
  }

  private func fixtureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-folder-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  #if os(macOS)
  private func unzip(_ archive: URL, into output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archive.path, output.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
  #endif
}
