import Foundation
import Logger

protocol MacDevtoolsCaptureFile: AnyObject {
  func write(_ data: Data) throws
  func offset() throws -> UInt64
  func truncate() throws
  func seekToEnd() throws
  func close() throws
}

final class MacDevtoolsCaptureFileHandle: MacDevtoolsCaptureFile {
  private let handle: FileHandle

  init(_ handle: FileHandle) { self.handle = handle }

  func write(_ data: Data) throws { try handle.write(contentsOf: data) }
  func offset() throws -> UInt64 { try handle.offset() }
  func truncate() throws { try handle.truncate(atOffset: 0) }
  func seekToEnd() throws { try handle.seekToEnd() }
  func close() throws { try handle.close() }
}

public final class MacDevtoolsLogCapture: LogSink, @unchecked Sendable {
  public static let shared = MacDevtoolsLogCapture()

  private static let enabledKey = "MacDevtools.logCaptureEnabled"
  static let maxFileEntries = 20_000

  static let maxFileBytes: UInt64 = 25 * 1024 * 1024

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "chat.inline.macdevtools.log-capture", qos: .utility)
  private let newline = Data([0x0A])
  private let encoder: JSONEncoder
  private let defaults: UserDefaults
  private let sinkID: String
  private let logFileURL: @Sendable () throws -> URL
  private let openFile: @Sendable (URL) throws -> any MacDevtoolsCaptureFile
  private let entryLimit: Int
  private let byteLimit: UInt64

  private var enabled: Bool
  private var generation: UInt64 = 0
  // Only the serial queue accesses the file and session counters.
  private var fileHandle: (any MacDevtoolsCaptureFile)?
  private var entryCount = 0
  private var didPrepareSessionFile = false

  init(
    defaults: UserDefaults = .standard,
    sinkID: String = "macdevtools.capture",
    logFileURL: @escaping @Sendable () throws -> URL = { try MacDevtoolsPaths.logFileURL() },
    openFile: @escaping @Sendable (URL) throws -> any MacDevtoolsCaptureFile = {
      try MacDevtoolsCaptureFileHandle(FileHandle(forWritingTo: $0))
    },
    entryLimit: Int = MacDevtoolsLogCapture.maxFileEntries,
    byteLimit: UInt64 = MacDevtoolsLogCapture.maxFileBytes
  ) {
    self.defaults = defaults
    self.sinkID = sinkID
    self.logFileURL = logFileURL
    self.openFile = openFile
    self.entryLimit = entryLimit
    self.byteLimit = byteLimit
    enabled = defaults.bool(forKey: Self.enabledKey)
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
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    let session = generation
    self.enabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)

    // Registry snapshots release their lock before calling write. Keeping these
    // transitions under our lock prevents old failure cleanup retiring a new sink.
    if enabled {
      Log.addSink(self, id: sinkID)
    } else {
      Log.removeSink(id: sinkID)
      queue.async { [weak self] in
        guard let self else { return }
        do {
          try self.closeFile()
        } catch {
          self.failSession(session)
        }
      }
    }
  }

  public func write(_ event: LogEvent) {
    lock.lock()
    defer { lock.unlock() }
    guard enabled else { return }
    let session = generation
    let entry = event.entry
    queue.async { [weak self] in
      self?.append(entry, session: session)
    }
  }

  private func append(_ entry: LogEntry, session: UInt64) {
    lock.lock()
    let admitted = enabled && generation == session
    lock.unlock()
    guard admitted else { return }

    do {
      let data = try encoder.encode(entry)
      let size = UInt64(data.count) + UInt64(newline.count)
      guard size <= byteLimit else { return }
      let handle = try fileHandleForWriting()
      try truncateIfNeeded(handle, nextWriteSize: size)
      try handle.write(data)
      try handle.write(newline)
      entryCount += 1
    } catch {
      failSession(session)
    }
  }

  private func fileHandleForWriting() throws -> any MacDevtoolsCaptureFile {
    if let fileHandle {
      return fileHandle
    }

    let url = try logFileURL()
    if didPrepareSessionFile == false {
      try Data().write(to: url, options: .atomic)
      entryCount = 0
      didPrepareSessionFile = true
    } else if FileManager.default.fileExists(atPath: url.path) == false {
      try Data().write(to: url, options: .atomic)
      entryCount = 0
    }

    let handle = try openFile(url)
    // Own it before the initial seek, so that failure can retire it too.
    fileHandle = handle
    try handle.seekToEnd()
    return handle
  }

  private func truncateIfNeeded(_ handle: any MacDevtoolsCaptureFile, nextWriteSize: UInt64) throws {
    let offset = try handle.offset()
    guard entryCount >= entryLimit
      || offset > byteLimit - nextWriteSize
    else { return }

    try handle.truncate()
    try handle.seekToEnd()
    entryCount = 0
  }

  private func closeFile() throws {
    let handle = fileHandle
    fileHandle = nil
    try handle?.close()
  }

  private func failSession(_ session: UInt64) {
    // A partial JSONL tail must not be reused after explicit re-enablement.
    didPrepareSessionFile = false
    entryCount = 0
    try? closeFile()

    lock.lock()
    defer { lock.unlock() }
    guard generation == session else { return }
    enabled = false
    generation &+= 1
    defaults.set(false, forKey: Self.enabledKey)
    Log.removeSink(id: sinkID)
    // Never report this failure through Log: this is one of its sinks.
  }

  func waitForPendingWrites() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }
}
