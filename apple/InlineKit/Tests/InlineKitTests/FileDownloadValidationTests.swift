import Foundation
import Testing
@testable import InlineKit

@Suite("Downloaded file validation")
struct FileDownloadValidationTests {
  @Test("HTTP error bodies cannot become downloaded files", arguments: [302, 403, 404, 413, 500, 503])
  func rejectsHTTPErrorBodies(status: Int) throws {
    let response = try response(status: status)
    #expect(throws: FileDownloadValidationError.httpStatus(status)) {
      try DownloadedFileValidation.validateHTTPResponse(response)
    }
  }

  @Test("Missing and non-HTTP responses fail closed")
  func rejectsInvalidResponse() {
    for response in [nil, URLResponse(
      url: URL(string: "https://download.invalid/file")!,
      mimeType: "application/octet-stream", expectedContentLength: 3, textEncodingName: nil
    )] {
      #expect(throws: FileDownloadValidationError.invalidHTTPResponse) {
        try DownloadedFileValidation.validateHTTPResponse(response)
      }
    }
  }

  @Test("Truncated and oversized documents are rejected before publication", arguments: [2, 4])
  func rejectsIncorrectDocumentLength(actualByteCount: Int) throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(repeating: 0x41, count: actualByteCount).write(to: file)
    #expect(throws: FileDownloadValidationError.byteCountMismatch(expected: 3, actual: Int64(actualByteCount))) {
      try DownloadedFileValidation.validateDocumentFile(at: file, expectedByteCount: 3)
    }
  }

  @Test("Compressed and resumed responses validate the assembled file", arguments: [200, 206])
  func acceptsCompleteMaterializedDocument(status: Int) throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(repeating: 0x41, count: 100).write(to: file)
    // The wire length can describe compressed bytes or the remaining range,
    // while URLSession's finished temporary file contains the whole document.
    let headers = status == 206
      ? ["Content-Length": "25", "Content-Range": "bytes 75-99/100"]
      : ["Content-Length": "25", "Content-Encoding": "gzip"]
    try DownloadedFileValidation.validateHTTPResponse(response(status: status, headers: headers))
    try DownloadedFileValidation.validateDocumentFile(at: file, expectedByteCount: 100)
  }

  @Test("A 500 MB materialized document passes the same size check")
  func accepts500MBFile() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 500_000_000)
    try DownloadedFileValidation.validateDocumentFile(at: file, expectedByteCount: 500_000_000)
  }

  @Test("Legacy documents without a known size remain downloadable")
  func acceptsUnknownDocumentSize() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([1, 2, 3]).write(to: file)
    try DownloadedFileValidation.validateDocumentFile(at: file, expectedByteCount: 0)
  }

  private func response(status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
    try #require(HTTPURLResponse(
      url: URL(string: "https://download.invalid/file")!,
      statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
    ))
  }

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("inline-download-validation-\(UUID().uuidString)")
  }
}
