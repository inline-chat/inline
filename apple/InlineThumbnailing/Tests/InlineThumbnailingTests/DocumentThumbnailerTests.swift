import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import InlineThumbnailing

@Suite("Document thumbnailing")
struct DocumentThumbnailerTests {
  private let thumbnailer = DocumentThumbnailer()

  @Test("enables supported cohorts without admitting risky extensions")
  func formatPolicy() {
    let policy = ThumbnailPolicy(
      enabledCohorts: [.core, .structuredText, .modernDocuments, .webDocuments],
      systemVersion: ThumbnailSystemVersion(major: 99)
    )

    #expect(descriptor("report.pdf", policy: policy)?.cohort == .core)
    #expect(descriptor("report.docx", policy: policy)?.cohort == .modernDocuments)
    #expect(descriptor("data.json", policy: policy)?.cohort == .structuredText)
    #expect(descriptor("diagram.svg", policy: policy)?.cohort == .webDocuments)
    #expect(descriptor("photo.jpg", policy: policy)?.cohort == .core)
    #expect(descriptor("photo.png", policy: policy)?.cohort == .core)
    #expect(descriptor("photo.heic", policy: policy)?.cohort == .core)
    #expect(descriptor("photo.webp", policy: policy)?.cohort == .core)
    #expect(descriptor("report.pages", policy: policy) == nil)
    #expect(descriptor("macro.docm", policy: policy) == nil)
    #expect(descriptor("script.command", policy: policy) == nil)
    #expect(descriptor("archive.zip", policy: policy) == nil)
    #expect(descriptor("icon.icns", contentType: .image, policy: policy) == nil)
    #expect(descriptor("image.avif", contentType: UTType(filenameExtension: "avif"), policy: policy) == nil)
    #expect(descriptor("image.unknown", contentType: .image, policy: policy) == nil)
    #expect(thumbnailer.canAttemptThumbnail(
      for: URL(fileURLWithPath: "report.docx"),
      policy: policy
    ))
    #expect(!thumbnailer.canAttemptThumbnail(
      for: URL(fileURLWithPath: "archive.zip"),
      policy: policy
    ))
  }

  @Test("respects cohort and operating-system gates")
  func policyGates() {
    let disabled = ThumbnailPolicy(
      enabledCohorts: [.core],
      systemVersion: ThumbnailSystemVersion(major: 99)
    )
    #expect(descriptor("report.docx", policy: disabled) == nil)

    #if os(macOS)
    let oldSystem = ThumbnailSystemVersion(major: 14)
    #else
    let oldSystem = ThumbnailSystemVersion(major: 17)
    #endif
    let unavailable = ThumbnailPolicy(
      enabledCohorts: Set(ThumbnailCohort.allCases),
      systemVersion: oldSystem
    )
    #expect(descriptor("report.pdf", policy: unavailable) == nil)
  }

  @Test("renders bounded deterministic structured-text thumbnails", arguments: [
    Fixture(name: "sample.csv", contents: "name,status\nAda,Ready\nGrace,Review", source: .delimitedText),
    Fixture(name: "sample.json", contents: "{\"project\":\"Inline\",\"ready\":true}", source: .json),
    Fixture(name: "sample.md", contents: "# Inline\n\nDocument previews\n\n- Safe\n- Fast", source: .markdown),
  ])
  func rendersStructuredText(fixture: Fixture) async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appendingPathComponent(fixture.name)
      try Data(fixture.contents.utf8).write(to: url)
      let artifact = try #require(await thumbnailer.thumbnail(for: url, policy: enabledPolicy))

      #expect(artifact.source == fixture.source)
      #expect(artifact.jpegData.starts(with: [0xFF, 0xD8]))
      #expect(artifact.pixelWidth > 0 && artifact.pixelWidth <= 320)
      #expect(artifact.pixelHeight > 0 && artifact.pixelHeight <= 320)
    }
  }

  @Test("renders a PDF through ImageIO")
  func rendersPDF() async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("sample.pdf")
      var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
      let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
      context.fill(CGRect(x: 40, y: 40, width: 532, height: 712))
      context.endPDFPage()
      context.closePDF()

      let artifact = try #require(await thumbnailer.thumbnail(for: url, policy: enabledPolicy))
      #expect(artifact.source == .imageIO)
      #expect(max(artifact.pixelWidth, artifact.pixelHeight) <= 320)
    }
  }

  @Test("fails soft for unsupported and binary files")
  func failsSoft() async throws {
    try await withTemporaryDirectory { directory in
      let unsupported = directory.appendingPathComponent("payload.bin")
      try Data([0, 1, 2, 3]).write(to: unsupported)
      #expect(await thumbnailer.thumbnail(for: unsupported, policy: enabledPolicy) == nil)

      let disabled = ThumbnailPolicy(
        enabledCohorts: [.core],
        systemVersion: ThumbnailSystemVersion(major: 99)
      )
      let text = directory.appendingPathComponent("notes.txt")
      try Data("hello".utf8).write(to: text)
      #expect(await thumbnailer.thumbnail(for: text, policy: disabled) == nil)
    }
  }

  private var enabledPolicy: ThumbnailPolicy {
    ThumbnailPolicy(
      enabledCohorts: [.core, .structuredText, .modernDocuments, .webDocuments],
      systemVersion: ThumbnailSystemVersion(major: 99)
    )
  }

  private func descriptor(
    _ name: String,
    contentType: UTType? = nil,
    policy: ThumbnailPolicy
  ) -> ThumbnailFormatDescriptor? {
    ThumbnailFormatRegistry.descriptor(
      for: URL(fileURLWithPath: name),
      contentType: contentType,
      policy: policy
    )
  }
}

struct Fixture: Sendable, CustomTestStringConvertible {
  let name: String
  let contents: String
  let source: ThumbnailSource

  var testDescription: String { name }
}

private func withTemporaryDirectory<T>(
  _ operation: (URL) async throws -> T
) async throws -> T {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("inline-thumbnail-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try await operation(directory)
}
