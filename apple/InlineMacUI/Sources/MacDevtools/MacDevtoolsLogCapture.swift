import Foundation
import Logger

public final class MacDevtoolsLogCapture: LogSink, @unchecked Sendable {
  public static let shared = MacDevtoolsLogCapture()

  private static let sinkID = "macdevtools.capture"
  private static let enabledKey = "MacDevtools.logCaptureEnabled"
  static let maxFileEntries = 20_000

  private static let maxFileBytes: UInt64 = 25 * 1024 * 1024

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "chat.inline.macdevtools.log-capture", qos: .utility)
  private let newline = Data([0x0A])
  private let encoder: JSONEncoder

  private var enabled: Bool
  private var fileHandle: FileHandle?
  private var entryCount = 0
  private var didPrepareSessionFile = false

  private init() {
    enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
  }

  public var isEnabled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }

  public func bootstrap() {
    setEnabled(isEnabled)
  }

  public func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)

    lock.lock()
    self.enabled = enabled
    lock.unlock()

    if enabled {
      Log.addSink(self, id: Self.sinkID)
    } else {
      Log.removeSink(id: Self.sinkID)
      queue.async { [weak self] in
        self?.closeFile()
      }
    }
  }

  public func write(_ event: LogEvent) {
    guard isEnabled else { return }

    let entry = event.entry
    queue.async { [weak self] in
      self?.append(entry)
    }
  }

  private func append(_ entry: LogEntry) {
    do {
      let handle = try fileHandleForWriting()
      let data = try encoder.encode(entry)
      truncateIfNeeded(handle, nextWriteSize: data.count + newline.count)
      handle.write(data)
      handle.write(newline)
      entryCount += 1
    } catch {
      closeFile()
    }
  }

  private func fileHandleForWriting() throws -> FileHandle {
    if let fileHandle {
      return fileHandle
    }

    let url = try MacDevtoolsPaths.logFileURL()
    if didPrepareSessionFile == false {
      try Data().write(to: url, options: .atomic)
      entryCount = 0
      didPrepareSessionFile = true
    } else if FileManager.default.fileExists(atPath: url.path) == false {
      FileManager.default.createFile(atPath: url.path, contents: nil)
      entryCount = 0
    }

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    fileHandle = handle
    return handle
  }

  private func truncateIfNeeded(_ handle: FileHandle, nextWriteSize: Int) {
    guard entryCount >= Self.maxFileEntries
      || handle.offsetInFile + UInt64(nextWriteSize) > Self.maxFileBytes
    else { return }

    handle.truncateFile(atOffset: 0)
    handle.seekToEndOfFile()
    entryCount = 0
  }

  private func closeFile() {
    do {
      try fileHandle?.close()
    } catch {}
    fileHandle = nil
  }
}
