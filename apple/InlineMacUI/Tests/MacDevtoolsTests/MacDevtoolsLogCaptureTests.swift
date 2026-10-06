import Foundation
import Logger
import Testing
@testable import MacDevtools

@Suite("Mac devtools log capture", .serialized)
struct MacDevtoolsLogCaptureTests {
  @Test("file failures disable, persist, retire the sink, and never log recursively", arguments: FileFailure.allCases)
  private func fileFailures(_ failure: FileFailure) async throws {
    let environment = try CaptureEnvironment()
    let files = FileProbe(failure: failure)
    let observer = EventCounter()
    let observerID = "\(environment.sinkID).observer"
    Log.addSink(observer, id: observerID)
    defer {
      Log.removeSink(id: observerID)
      Log.removeSink(id: environment.sinkID)
    }
    var capture: MacDevtoolsLogCapture? = environment.capture(files: files, entryLimit: 1)
    weak var retiredCapture = capture
    capture!.setEnabled(true)
    capture!.write(event("first"))
    if failure == .rotationTruncate || failure == .rotationSeek {
      capture!.write(event("second"))
    }
    await capture!.waitForPendingWrites()
    if failure == .close {
      capture!.setEnabled(false)
      await capture!.waitForPendingWrites()
    }

    #expect(!capture!.isEnabled)
    #expect(!environment.defaults.bool(forKey: CaptureEnvironment.enabledKey))
    let file = try #require(files.opened.first)
    #expect(file.failedOperation == failure)
    #expect(file.calls("close") == 1)
    let writeCalls = file.calls("write")
    for _ in 0 ..< 40 { capture!.write(event("after-failure")) }
    await capture!.waitForPendingWrites()
    #expect(files.opened.count == 1)
    #expect(file.calls("write") == writeCalls)
    #expect(observer.count == 0)
    capture = nil
    #expect(retiredCapture === nil)
  }

  @Test("an admitted backlog is suppressed after the first write fails")
  func suppressesBacklog() async throws {
    let environment = try CaptureEnvironment()
    let gate = WriteGate()
    let files = FileProbe(failure: .dataWrite, gate: gate)
    let capture = environment.capture(files: files)
    defer {
      gate.release()
      capture.setEnabled(false)
    }
    capture.setEnabled(true)
    capture.write(event("blocked"))
    try #require(await gate.waitUntilEntered())
    for _ in 0 ..< 100 { capture.write(event("queued")) }
    gate.release()
    await capture.waitForPendingWrites()

    #expect(!capture.isEnabled)
    #expect(!environment.defaults.bool(forKey: CaptureEnvironment.enabledKey))
    #expect(files.opened.count == 1)
    #expect(files.opened.first?.calls("write") == 1)
  }

  @Test("an old blocked failure cannot disable or retire an explicitly re-enabled generation")
  func reenableRacingOldFailure() async throws {
    let environment = try CaptureEnvironment()
    let gate = WriteGate()
    let files = FileProbe(failure: .dataWrite, gate: gate)
    var capture: MacDevtoolsLogCapture? = environment.capture(files: files)
    defer {
      gate.release()
      capture?.setEnabled(false)
      Log.removeSink(id: environment.sinkID)
    }
    capture!.setEnabled(true)
    capture!.write(event("blocked-old"))
    try #require(await gate.waitUntilEntered())
    capture!.write(event("queued-old"))
    capture!.setEnabled(false)
    capture!.setEnabled(true)
    let newEvents = [event("new-one"), event("new-two")]
    for event in newEvents { capture!.write(event) }
    gate.release()
    await capture!.waitForPendingWrites()

    #expect(capture!.isEnabled)
    #expect(environment.defaults.bool(forKey: CaptureEnvironment.enabledKey))
    #expect(files.opened.count == 2)
    #expect(files.opened.first?.calls("write") == 1)
    #expect(files.opened.first?.failedOperation == .dataWrite)
    #expect(files.opened.first?.calls("close") == 1)
    #expect(files.opened.last?.calls("write") == 4)
    #expect(try readEntries(environment.url) == newEvents.map(\.entry))
    weak var registeredCapture = capture
    capture = nil
    // Registry ownership proves stale failure cleanup did not remove the new sink.
    let survivor = try #require(registeredCapture)
    survivor.setEnabled(false)
    await survivor.waitForPendingWrites()
  }

  @Test("native seek and append failures disable capture", arguments: NativeHandleState.allCases)
  private func nativeHandleFailures(_ state: NativeHandleState) async throws {
    let environment = try CaptureEnvironment()
    try Data().write(to: environment.url)
    let handle: FileHandle
    switch state {
    case .closed:
      handle = try FileHandle(forWritingTo: environment.url)
      try handle.close()
    case .invalidDescriptor:
      handle = FileHandle(fileDescriptor: -1, closeOnDealloc: false)
    case .readOnly:
      handle = try FileHandle(forReadingFrom: environment.url)
    }
    let adapter = MacDevtoolsCaptureFileHandle(handle)
    #expect(throws: (any Error).self) { try adapter.write(Data([0x7B])) }
    if state == .readOnly {
      try adapter.seekToEnd()
      #expect(try adapter.offset() == 0)
    } else {
      #expect(throws: (any Error).self) { try adapter.seekToEnd() }
    }
    let source = FixedFileSource(adapter)
    let capture = MacDevtoolsLogCapture(
      defaults: environment.defaults,
      sinkID: environment.sinkID,
      logFileURL: { environment.url },
      openFile: { _ in source.open() }
    )
    defer { capture.setEnabled(false) }
    capture.setEnabled(true)
    capture.write(event("native-failure"))
    await capture.waitForPendingWrites()

    #expect(!capture.isEnabled)
    #expect(!environment.defaults.bool(forKey: CaptureEnvironment.enabledKey))
    #expect(source.openCount == 1)
    #expect(try Data(contentsOf: environment.url).isEmpty)
    for _ in 0 ..< 20 { capture.write(event("after-native-failure")) }
    await capture.waitForPendingWrites()
    #expect(source.openCount == 1)
  }

  @Test("real JSONL rotates at the entry cap and retains complete records")
  func entryRotation() async throws {
    let environment = try CaptureEnvironment()
    let files = FileProbe()
    let capture = environment.capture(files: files, entryLimit: 2)
    defer { capture.setEnabled(false) }
    let events = (1 ... 5).map { event("entry-\($0)") }
    capture.setEnabled(true)
    for event in events.prefix(2) { capture.write(event) }
    await capture.waitForPendingWrites()
    #expect(try readEntries(environment.url) == events.prefix(2).map(\.entry))
    for event in events.dropFirst(2) { capture.write(event) }
    await capture.waitForPendingWrites()

    #expect(try readEntries(environment.url) == [events[4].entry])
    #expect(files.opened.first?.calls("truncate") == 2)
    #expect(capture.isEnabled)
  }

  @Test("real JSONL fills the byte cap exactly then rotates before overflowing")
  func byteRotation() async throws {
    let environment = try CaptureEnvironment()
    let events = [event("001"), event("002"), event("003")]
    let recordSize = try encodedSize(events[0])
    let cap = recordSize * 2
    let files = FileProbe()
    let capture = environment.capture(files: files, byteLimit: cap)
    defer { capture.setEnabled(false) }
    capture.setEnabled(true)
    for event in events.prefix(2) { capture.write(event) }
    await capture.waitForPendingWrites()
    #expect(try UInt64(Data(contentsOf: environment.url).count) == cap)
    #expect(try readEntries(environment.url) == events.prefix(2).map(\.entry))
    capture.write(events[2])
    await capture.waitForPendingWrites()

    #expect(try UInt64(Data(contentsOf: environment.url).count) == recordSize)
    #expect(try readEntries(environment.url) == [events[2].entry])
    #expect(files.opened.first?.calls("truncate") == 1)
    #expect(capture.isEnabled)
  }

  @Test("oversized records are skipped without opening or poisoning a bounded session")
  func skipsOversizedRecords() async throws {
    let environment = try CaptureEnvironment()
    let events = [event("001"), event("002"), event("003")]
    let cap = try encodedSize(events[0]) * 2
    let oversized = event(String(repeating: "x", count: 4096))
    #expect(try encodedSize(oversized) > cap)
    let files = FileProbe()
    let capture = environment.capture(files: files, byteLimit: cap)
    defer { capture.setEnabled(false) }
    capture.setEnabled(true)
    capture.write(oversized)
    await capture.waitForPendingWrites()
    #expect(files.opened.isEmpty)
    capture.write(events[0])
    capture.write(oversized)
    capture.write(events[1])
    await capture.waitForPendingWrites()
    #expect(try readEntries(environment.url) == events.prefix(2).map(\.entry))
    #expect(try UInt64(Data(contentsOf: environment.url).count) <= cap)
    capture.write(events[2])
    await capture.waitForPendingWrites()

    #expect(try readEntries(environment.url) == [events[2].entry])
    #expect(try UInt64(Data(contentsOf: environment.url).count) <= cap)
    #expect(files.opened.count == 1)
    #expect(capture.isEnabled)
    #expect(environment.defaults.bool(forKey: CaptureEnvironment.enabledKey))
  }

  @Test("re-enabling after a partial JSONL line starts a clean decodable file")
  func recoversFromPartialLine() async throws {
    let environment = try CaptureEnvironment()
    let files = FileProbe(failure: .newlineWrite)
    let capture = environment.capture(files: files)
    defer { capture.setEnabled(false) }
    capture.setEnabled(true)
    capture.write(event("partial"))
    await capture.waitForPendingWrites()
    let partial = try Data(contentsOf: environment.url)
    #expect(!partial.isEmpty)
    #expect(partial.last != 0x0A)
    #expect(!capture.isEnabled)
    let recovered = event("recovered")
    capture.setEnabled(true)
    capture.write(recovered)
    await capture.waitForPendingWrites()

    #expect(try readEntries(environment.url) == [recovered.entry])
    #expect(files.opened.count == 2)
    #expect(capture.isEnabled)
    #expect(environment.defaults.bool(forKey: CaptureEnvironment.enabledKey))
  }
}

private enum FileFailure: String, CaseIterable, Sendable {
  case dataWrite, newlineWrite, offset, initialSeek, rotationTruncate, rotationSeek, close
}

private enum NativeHandleState: CaseIterable, Equatable, Sendable { case closed, invalidDescriptor, readOnly }
private enum FixtureError: Error { case injected, blockedWriteTimedOut, invalidDefaults, incompleteJSONL }

private struct CaptureEnvironment: @unchecked Sendable {
  static let enabledKey = "MacDevtools.logCaptureEnabled"
  let defaults: UserDefaults
  let sinkID = "macdevtools.tests.\(UUID().uuidString)"
  let url: URL

  init() throws {
    guard let defaults = UserDefaults(suiteName: "macdevtools.tests.\(UUID().uuidString)") else {
      throw FixtureError.invalidDefaults
    }
    self.defaults = defaults
    defaults.set(false, forKey: Self.enabledKey)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("macdevtools-capture-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("capture.jsonl")
    // UUID suites and small owned files are deliberately retained; no defaults domain is cleared.
  }

  func capture(files: FileProbe, entryLimit: Int = 20, byteLimit: UInt64 = 32_768) -> MacDevtoolsLogCapture {
    MacDevtoolsLogCapture(
      defaults: defaults,
      sinkID: sinkID,
      logFileURL: { [url] in url },
      openFile: { try files.open($0) },
      entryLimit: entryLimit,
      byteLimit: byteLimit
    )
  }
}

private final class FileProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let failure: FileFailure?
  private let gate: WriteGate?
  private var handles: [ControlledFile] = []
  var opened: [ControlledFile] { lock.withLock { handles } }

  init(failure: FileFailure? = nil, gate: WriteGate? = nil) {
    self.failure = failure
    self.gate = gate
  }

  func open(_ url: URL) throws -> any MacDevtoolsCaptureFile {
    let handle = try FileHandle(forWritingTo: url)
    return lock.withLock {
      let file = ControlledFile(handle, failure: handles.isEmpty ? failure : nil, gate: handles.isEmpty ? gate : nil)
      handles.append(file)
      return file
    }
  }
}

private final class ControlledFile: MacDevtoolsCaptureFile, @unchecked Sendable {
  private let handle: MacDevtoolsCaptureFileHandle
  private let failure: FileFailure?
  private let gate: WriteGate?
  private let lock = NSLock()
  private var counts: [String: Int] = [:]
  private var failed: FileFailure?
  var failedOperation: FileFailure? { lock.withLock { failed } }

  init(_ handle: FileHandle, failure: FileFailure?, gate: WriteGate?) {
    self.handle = MacDevtoolsCaptureFileHandle(handle)
    self.failure = failure
    self.gate = gate
  }

  func calls(_ operation: String) -> Int { lock.withLock { counts[operation, default: 0] } }

  private func record(_ operation: String) -> (Int, Bool) {
    lock.withLock {
      counts[operation, default: 0] += 1
      let count = counts[operation, default: 0]
      let point: FileFailure? = switch (operation, count) {
      case ("write", 1): .dataWrite
      case ("write", 2): .newlineWrite
      case ("offset", 1): .offset
      case ("seek", 1): .initialSeek
      case ("truncate", 1): .rotationTruncate
      case ("seek", 2): .rotationSeek
      case ("close", 1): .close
      default: nil
      }
      let shouldFail = point != nil && point == failure
      if shouldFail { failed = point }
      return (count, shouldFail)
    }
  }

  func write(_ data: Data) throws {
    let (count, fail) = record("write")
    if count == 1 { try gate?.block() }
    if fail { throw FixtureError.injected }
    try handle.write(data)
  }

  func offset() throws -> UInt64 {
    if record("offset").1 { throw FixtureError.injected }
    return try handle.offset()
  }

  func truncate() throws {
    if record("truncate").1 { throw FixtureError.injected }
    try handle.truncate()
  }

  func seekToEnd() throws {
    if record("seek").1 { throw FixtureError.injected }
    try handle.seekToEnd()
  }

  func close() throws {
    let fail = record("close").1
    // Release the real descriptor even when simulating a reported close failure.
    try handle.close()
    if fail { throw FixtureError.injected }
  }
}

private final class WriteGate: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)

  func block() throws {
    entered.signal()
    guard released.wait(timeout: .now() + 5) == .success else { throw FixtureError.blockedWriteTimedOut }
  }

  func waitUntilEntered() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
      }
    }
  }

  func release() { released.signal() }
}

private final class EventCounter: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var events = 0
  var count: Int { lock.withLock { events } }
  func write(_ event: LogEvent) { lock.withLock { events += 1 } }
}

private final class FixedFileSource: @unchecked Sendable {
  private let file: any MacDevtoolsCaptureFile
  private let lock = NSLock()
  private var count = 0
  var openCount: Int { lock.withLock { count } }
  init(_ file: any MacDevtoolsCaptureFile) { self.file = file }
  func open() -> any MacDevtoolsCaptureFile {
    lock.withLock { count += 1 }
    return file
  }
}

private func event(_ message: String) -> LogEvent {
  LogEvent(entry: LogEntry(
    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
    level: .info,
    scope: "CaptureTest",
    message: message,
    error: nil,
    file: "CaptureTest.swift",
    fileName: "CaptureTest.swift",
    function: "captureTest()",
    line: 1,
    processIdentifier: 1,
    threadIdentifier: 1
  ), error: nil)
}

private func encodedSize(_ event: LogEvent) throws -> UInt64 {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.sortedKeys]
  return try UInt64(encoder.encode(event.entry).count) + 1
}

private func readEntries(_ url: URL) throws -> [LogEntry] {
  let data = try Data(contentsOf: url)
  guard data.isEmpty || data.last == 0x0A else { throw FixtureError.incompleteJSONL }
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try data.split(separator: 0x0A).map { try decoder.decode(LogEntry.self, from: Data($0)) }
}
