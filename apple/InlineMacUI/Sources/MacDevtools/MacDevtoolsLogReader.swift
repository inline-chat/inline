import Foundation
import Logger

struct MacDevtoolsLogReadResult: Sendable {
  let entries: [LogEntry]
  let didReset: Bool
}

actor MacDevtoolsLogReader {
  private let decoder: JSONDecoder
  private var offset: UInt64 = 0
  private var partialLine = ""

  init() {
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func reset() {
    offset = 0
    partialLine = ""
  }

  func readNewEntries(from url: URL) throws -> MacDevtoolsLogReadResult {
    guard FileManager.default.fileExists(atPath: url.path) else {
      reset()
      return MacDevtoolsLogReadResult(entries: [], didReset: true)
    }

    let size = try fileSize(at: url)
    let didReset = size < offset
    if didReset {
      reset()
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer {
      try? handle.close()
    }

    try handle.seek(toOffset: offset)
    let data = try handle.readToEnd() ?? Data()
    offset = try handle.offset()

    guard data.isEmpty == false,
          let text = String(data: data, encoding: .utf8)
    else {
      return MacDevtoolsLogReadResult(entries: [], didReset: didReset)
    }

    let parsed = parse(partialLine + text)
    partialLine = parsed.partial
    return MacDevtoolsLogReadResult(entries: parsed.entries, didReset: didReset)
  }

  private func parse(_ text: String) -> (entries: [LogEntry], partial: String) {
    let hasCompleteFinalLine = text.last == "\n"
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let partial = hasCompleteFinalLine ? "" : (lines.popLast() ?? "")

    let entries = lines.compactMap { line -> LogEntry? in
      guard line.isEmpty == false,
            let data = line.data(using: .utf8)
      else {
        return nil
      }
      return try? decoder.decode(LogEntry.self, from: data)
    }

    return (entries, partial)
  }

  private func fileSize(at url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else { return 0 }
    return size.uint64Value
  }
}
