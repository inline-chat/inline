import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

private actor PieceStaging: NativeUploadStaging {
  func stage(logicalID _: String, sourceURL: URL) -> URL { sourceURL }
  func discard(logicalID _: String) {}
}

private enum PieceRejected: Error { case oldServer }

/// A server that takes parts in pieces and checks every byte lands where it belongs.
private actor PieceServerMock: NativeUploadRPCTransport {
  struct Save: Equatable {
    let part: UInt32
    let offset: UInt32?
    let length: Int
  }

  private let body: Data
  private let granularity: UInt32?
  private let rejectsPieces: Bool
  private let takesProposedIDs: Bool
  private let createDelay: Duration
  /// Rejects a part for an upload whose create hasn't returned (a server on another machine).
  private let rejectsEarlyParts: Bool
  /// Delays the first save of part 0 after an upload has finished (a slow first part on the
  /// second upload).
  private let firstPartDelay: Duration
  private var createdIDs: Set<Data> = []
  private var delayedFirstPart = false
  private var finishedUploads = 0
  private(set) var events: [String] = []
  private var createCount: UInt8 = 0
  private(set) var finishThumbnails: [String?] = []
  private(set) var createThumbnails: [String?] = []
  private var received: [Data: [UInt32: Data]] = [:]
  private var filled: [Data: [UInt32: Int]] = [:]
  private(set) var saves: [Save] = []
  private(set) var methods: [InlineProtocol.Method] = []
  private(set) var inlineData: Data?

  init(
    body: Data,
    granularity: UInt32? = 16_384,
    rejectsPieces: Bool = false,
    takesProposedIDs: Bool = false,
    createDelay: Duration = .zero,
    rejectsEarlyParts: Bool = false,
    firstPartDelay: Duration = .zero
  ) {
    self.body = body
    self.granularity = granularity
    self.rejectsPieces = rejectsPieces
    self.takesProposedIDs = takesProposedIDs
    self.createDelay = createDelay
    self.rejectsEarlyParts = rejectsEarlyParts
    self.firstPartDelay = firstPartDelay
  }

  private var partCount: UInt32 { UInt32((body.count + 524_287) / 524_288) }

  private func partLength(_ index: UInt32) -> Int {
    min(524_288, body.count - Int(index) * 524_288)
  }

  private func acceptedParts(_ upload: Data) -> [UInt32] {
    (0 ..< partCount).filter { filled[upload]?[$0] == partLength($0) }
  }

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    methods.append(method)
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      events.append("create")
      createThumbnails.append(create.hasThumbnailFileUniqueID ? create.thumbnailFileUniqueID : nil)
      if createDelay > .zero { try await Task.sleep(for: createDelay) }
      events.append("created")
      if create.hasInlineData { inlineData = create.inlineData }
      var result = CreateUploadResult()
      // Like a real server, each upload it picks an ID for gets its own.
      createCount += 1
      result.uploadID = takesProposedIDs && create.hasUploadID
        ? create.uploadID
        : Data(repeating: 9, count: 15) + Data([createCount])
      result.partSize = 524_288
      result.partCount = partCount
      if let granularity { result.pieceGranularity = granularity }
      createdIDs.insert(result.uploadID)
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      saves.append(Save(part: save.partIndex, offset: save.hasOffset ? save.offset : nil, length: save.data.count))
      events.append("save \(save.partIndex)")
      if rejectsEarlyParts, !createdIDs.contains(save.uploadID) {
        events.append("rejected \(save.partIndex)")
        throw PieceRejected.oldServer
      }
      if firstPartDelay > .zero, save.partIndex == 0, !delayedFirstPart, finishedUploads > 0 {
        delayedFirstPart = true
        try await Task.sleep(for: firstPartDelay)
      }
      if save.hasOffset, rejectsPieces { throw PieceRejected.oldServer }
      let offset = save.hasOffset ? Int(save.offset) : 0
      let start = Int(save.partIndex) * 524_288 + offset
      #expect(save.data == body.subdata(in: start ..< start + save.data.count))
      if let granularity, save.hasOffset {
        #expect(offset % Int(granularity) == 0)
      }
      var part = received[save.uploadID]?[save.partIndex] ?? Data(count: partLength(save.partIndex))
      part.replaceSubrange(offset ..< offset + save.data.count, with: save.data)
      received[save.uploadID, default: [:]][save.partIndex] = part
      filled[save.uploadID, default: [:]][save.partIndex, default: 0] += save.data.count
      return .saveUploadPart(SaveUploadPartResult())
    case (.cancelUpload, .cancelUpload):
      var result = CancelUploadResult()
      result.canceled = true
      return .cancelUpload(result)
    case let (.getUploadState, .getUploadState(input)):
      var state = GetUploadStateResult()
      state.status = .uploading
      state.acceptedParts = acceptedParts(input.uploadID)
      return .getUploadState(state)
    case let (.finishUpload, .finishUpload(input)):
      finishThumbnails.append(input.hasThumbnailFileUniqueID ? input.thumbnailFileUniqueID : nil)
      var finish = FinishUploadResult()
      let accepted = acceptedParts(input.uploadID)
      let missing = (0 ..< partCount).filter { !accepted.contains($0) }
      if !missing.isEmpty {
        var parts = UploadMissingParts()
        parts.partIndices = missing
        finish.missing = parts
        return .finishUpload(finish)
      }
      let parts = received[input.uploadID] ?? [:]
      let assembled = (0 ..< partCount).reduce(into: Data()) { $0.append(parts[$1]!) }
      #expect(assembled == body)
      var complete = UploadComplete()
      complete.fileUniqueID = "IND_pieces"
      finishedUploads += 1
      finish.complete = complete
      return .finishUpload(finish)
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int64] = []
  func append(_ value: Int64) { lock.withLock { values.append(value) } }
  var recorded: [Int64] { lock.withLock { values } }
}

private func sourceFile(_ body: Data) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("inline-native-upload-pieces-\(UUID().uuidString)")
  try body.write(to: url)
  return url
}

private func pattern(_ count: Int) -> Data {
  Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

@Suite("Native upload pieces")
struct NativeUploadPiecesTests {
  @Test("the first part ramps from 16 KiB; later parts go in 128 KiB pieces")
  func pieceLayout() {
    let first = NativeUploadPieces.ranges(partLength: 524_288, granularity: 16_384, rampUp: true)!
    #expect(first.map(\.count) == [16_384, 16_384, 32_768, 65_536, 131_072, 262_144])
    #expect(first.last?.upperBound == 524_288)
    let later = NativeUploadPieces.ranges(partLength: 524_288, granularity: 16_384, rampUp: false)!
    #expect(later.map(\.count) == [131_072, 131_072, 131_072, 131_072])
    let tail = NativeUploadPieces.ranges(partLength: 40_000, granularity: 16_384, rampUp: true)!
    #expect(tail == [0 ..< 16_384, 16_384 ..< 32_768, 32_768 ..< 40_000])
    // A coarser granularity rounds pieces up; an unusable one sends the part whole.
    let coarse = NativeUploadPieces.ranges(partLength: 524_288, granularity: 65_536, rampUp: true)!
    #expect(coarse.map(\.count) == [65_536, 65_536, 65_536, 65_536, 131_072, 131_072])
    #expect(NativeUploadPieces.ranges(partLength: 524_288, granularity: 0, rampUp: true) == nil)
    #expect(NativeUploadPieces.ranges(partLength: 524_288, granularity: 524_288, rampUp: true) == nil)
    #expect(NativeUploadPieces.ranges(partLength: 524_288, granularity: 24_576, rampUp: true) == nil)
  }

  @Test("small or fast files go inline; slower ones go in pieces")
  func inlineChoice() {
    let part: Int64 = 524_288
    #expect(NativeUploadPieces.sendsInline(byteCount: 100_000, partSize: part, bytesPerSecond: nil))
    #expect(!NativeUploadPieces.sendsInline(byteCount: 400_000, partSize: part, bytesPerSecond: nil))
    #expect(NativeUploadPieces.sendsInline(byteCount: 400_000, partSize: part, bytesPerSecond: 2_000_000))
    #expect(!NativeUploadPieces.sendsInline(byteCount: 400_000, partSize: part, bytesPerSecond: 300_000))
    #expect(!NativeUploadPieces.sendsInline(byteCount: 600_000, partSize: part, bytesPerSecond: 10_000_000))
  }

  @Test("progress counts acknowledged pieces and never goes backwards")
  func progressMeter() {
    let log = ProgressLog()
    let meter = NativeUploadProgressMeter(total: 1_000) { sent, total in
      #expect(total == 1_000)
      log.append(sent)
    }
    meter.accepted(0)
    meter.pieceAcknowledged(part: 0, bytes: 100)
    meter.pieceAcknowledged(part: 1, bytes: 50)
    meter.partReset(1) // resent from scratch: no rewind shown
    meter.pieceAcknowledged(part: 0, bytes: 100)
    meter.accepted(500, parts: [0])
    meter.accepted(400, parts: [0]) // a part reported missing at finish
    meter.complete()
    #expect(log.recorded == [0, 100, 150, 200, 500, 1_000])
  }

  @Test("a multi-part file goes in pieces with early progress, and the server gets every byte")
  func uploadsInPieces() async throws {
    let body = pattern(524_288 + 90_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    let progress = ProgressLog()
    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:pieces", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream",
      kind: .document
    ), progress: { sent, _ in progress.append(sent) })
    #expect(complete.fileUniqueID == "IND_pieces")
    let saves = await server.saves
    let firstPart = saves.filter { $0.part == 0 }
    #expect(firstPart.map(\.length).sorted() == [16_384, 16_384, 32_768, 65_536, 131_072, 262_144])
    #expect(firstPart.allSatisfy { $0.offset != nil })
    // The 90 000-byte tail fits one 128 KiB piece, so it goes whole.
    #expect(saves.filter { $0.part == 1 } == [.init(part: 1, offset: nil, length: 90_000)])
    let values = progress.recorded
    #expect(values == values.sorted())
    #expect(values.count >= 7)
    #expect(values.dropFirst().first.map { $0 <= 131_072 } == true)
    #expect(values.last == Int64(body.count))
  }

  @Test("a one-part file goes in pieces when it would be slow inline")
  func onePartInPieces() async throws {
    let body = pattern(300_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:one-part", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream",
      kind: .document
    ), progress: { _, _ in })
    #expect(await server.inlineData == nil)
    #expect(await server.methods.first == .createUpload)
    #expect(await server.methods.last == .finishUpload)
    // 16, 16, 32, 64 and 128 KiB, then the last 37 856 bytes.
    // Pieces go out together, so they may reach the server in any order.
    #expect(await server.saves.map(\.length).sorted() == [16_384, 16_384, 32_768, 37_856, 65_536, 131_072])
  }

  @Test("a server that refuses pieces gets the part whole on the retry")
  func fallsBackToWholeParts() async throws {
    let body = pattern(524_288)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, rejectsPieces: true)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:fallback", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream",
      kind: .document
    ), progress: { _, _ in })
    #expect(complete.fileUniqueID == "IND_pieces")
    #expect(await server.saves.last == .init(part: 0, offset: nil, length: 524_288))
  }

  @Test("a held finish moves every byte, then finishes only once the gate opens")
  func heldFinishWaitsForGate() async throws {
    let body = pattern(200_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    let gate = NativeUploadFinishGate()
    let upload = Task {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:early", fileURL: source, fileName: "a.jpg", mimeType: "image/jpeg",
        kind: .photo, finishGate: gate
      ), progress: { _, _ in })
    }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while await server.saves.reduce(0, { $0 + $1.length }) < body.count, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(50))
    // Small enough to go inline, but a held finish never goes inline (inline finishes in create).
    #expect(await server.inlineData == nil)
    #expect(await server.methods.contains(.finishUpload) == false)
    gate.open()
    #expect(try await upload.value.fileUniqueID == "IND_pieces")
    #expect(await server.methods.last == .finishUpload)
  }

  @Test("canceling an upload held at its finish cancels it on the server")
  func canceledHeldUploadIsDiscarded() async throws {
    let body = pattern(200_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    let upload = Task {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:removed", fileURL: source, fileName: "a.jpg", mimeType: "image/jpeg",
        kind: .photo, finishGate: NativeUploadFinishGate()
      ), progress: { _, _ in })
    }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while await server.saves.reduce(0, { $0 + $1.length }) < body.count, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    upload.cancel()
    await #expect(throws: CancellationError.self) { try await upload.value }
    #expect(await server.methods.contains(.cancelUpload))
    #expect(await server.methods.contains(.finishUpload) == false)
  }

  @Test("after a server takes the proposed upload ID, the next upload's first part goes ahead of the create reply")
  func firstPartGoesAheadOfCreate() async throws {
    let body = pattern(524_288 + 50_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true, createDelay: .milliseconds(150))
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    func send(_ id: String) async throws {
      _ = try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: id, fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream", kind: .document
      ), progress: { _, _ in })
    }
    try await send("document:first")
    let firstEvents = await server.events
    // Nothing known about the server yet: parts wait for the create reply.
    #expect(firstEvents.firstIndex(of: "created")! < firstEvents.firstIndex(of: "save 0")!)
    #expect(coordinator.acceptsThumbnailAtFinish)

    try await send("document:second")
    let events = Array(await server.events.dropFirst(firstEvents.count))
    #expect(events.firstIndex(of: "save 0")! < events.firstIndex(of: "created")!)
    #expect(events.contains("save 1"))
  }

  @Test("an old server that ignores the proposed ID keeps parts behind the create reply")
  func oldServerWaitsForCreate() async throws {
    let body = pattern(524_288 + 50_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, createDelay: .milliseconds(50))
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    for id in ["document:a", "document:b"] {
      _ = try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: id, fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream", kind: .document
      ), progress: { _, _ in })
    }
    let events = await server.events
    let secondCreate = events.lastIndex(of: "create")!
    let tail = Array(events[secondCreate...])
    #expect(tail.firstIndex(of: "created")! < tail.firstIndex(of: "save 0")!)
    #expect(coordinator.acceptsThumbnailAtFinish == false)
  }

  @Test("a thumbnail named at finish goes in the finish, not the create")
  func thumbnailAtFinish() async throws {
    let body = pattern(300_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "video:1", fileURL: source, fileName: "a.mp4", mimeType: "video/mp4", kind: .document,
      thumbnailAtFinish: { "INP_thumb" }
    ), progress: { _, _ in })
    #expect(await server.createThumbnails == [nil])
    #expect(await server.finishThumbnails == ["INP_thumb"])
    #expect(await server.inlineData == nil)
  }

  /// Uploads `body` once to teach the coordinator that the server takes proposed IDs.
  private func warmedCoordinator(_ server: PieceServerMock, source: URL) async throws -> DurableUploadCoordinator {
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:warm", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream", kind: .document
    ), progress: { _, _ in })
    #expect(coordinator.acceptsThumbnailAtFinish)
    return coordinator
  }

  @Test("a part sent ahead that the server rejects is sent again after the create")
  func rejectedPartAheadIsResent() async throws {
    let body = pattern(524_288 + 70_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true, createDelay: .milliseconds(80), rejectsEarlyParts: true)
    let coordinator = try await warmedCoordinator(server, source: source)
    let before = await server.events.count
    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:resend", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream", kind: .document
    ), progress: { _, _ in })
    #expect(complete.fileUniqueID == "IND_pieces")
    let events = Array(await server.events.dropFirst(before))
    #expect(events.contains("rejected 0"))
    // Accepted on a later save of part 0, after the create returned.
    let created = events.firstIndex(of: "created")!
    #expect(events[created...].contains("save 0"))
  }

  @Test("a single-part file goes ahead of the create and completes")
  func singlePartGoesAhead() async throws {
    let body = pattern(200_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true, createDelay: .milliseconds(120))
    let coordinator = try await warmedCoordinator(server, source: source)
    let before = await server.events.count
    let gate = NativeUploadFinishGate()
    gate.open()
    // A held finish never sends inline, so the part goes as a part.
    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:single", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream",
      kind: .document, finishGate: gate
    ), progress: { _, _ in })
    #expect(complete.fileUniqueID == "IND_pieces")
    let events = Array(await server.events.dropFirst(before))
    #expect(events.firstIndex(of: "save 0")! < events.firstIndex(of: "created")!)
  }

  @Test("canceling while the part sent ahead is still moving returns promptly")
  func cancelDuringPartAhead() async throws {
    let body = pattern(524_288 + 10_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true, firstPartDelay: .seconds(20))
    let coordinator = try await warmedCoordinator(server, source: source)
    let upload = Task {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "document:cancel", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream",
        kind: .document
      ), progress: { _, _ in })
    }
    try await Task.sleep(for: .milliseconds(300))
    let clock = ContinuousClock()
    let canceledAt = clock.now
    upload.cancel()
    let result = await upload.result
    #expect(clock.now - canceledAt < .seconds(3))
    // It was still waiting on the slow part, so it ended canceled rather than complete.
    #expect((try? result.get()) == nil)
    #expect(await server.finishThumbnails.count == 1)
  }

  @Test("a thumbnail that fails to upload leaves the file without one")
  func failedThumbnailAtFinish() async throws {
    let body = pattern(300_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    struct ThumbnailFailed: Error {}
    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "video:nothumb", fileURL: source, fileName: "a.mp4", mimeType: "video/mp4", kind: .document,
      thumbnailAtFinish: { throw ThumbnailFailed() }
    ), progress: { _, _ in })
    #expect(complete.fileUniqueID == "IND_pieces")
    #expect(await server.finishThumbnails == [nil])
  }

  @Test("a held upload names its thumbnail only once Send opens the finish")
  func heldThumbnailWaitsForSend() async throws {
    let body = pattern(300_000)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, takesProposedIDs: true)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    let gate = NativeUploadFinishGate()
    let asked = ProgressLog()
    let upload = Task {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "video:held", fileURL: source, fileName: "a.mp4", mimeType: "video/mp4", kind: .document,
        finishGate: gate, thumbnailAtFinish: { asked.append(1); return "INP_held" }
      ), progress: { _, _ in })
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(await server.finishThumbnails.isEmpty)
    #expect(asked.recorded.isEmpty)
    gate.open()
    let complete = try await upload.value
    #expect(complete.fileUniqueID == "IND_pieces")
    #expect(await server.finishThumbnails == ["INP_held"])
  }

  @Test("the proposed upload ID is fixed per client upload ID")
  func proposedIDIsStable() {
    let client = Data(repeating: 4, count: 16)
    let proposed = DurableUploadCoordinator.proposedUploadID(clientUploadID: client)
    #expect(proposed.count == 16)
    #expect(proposed == DurableUploadCoordinator.proposedUploadID(clientUploadID: client))
    #expect(proposed != DurableUploadCoordinator.proposedUploadID(clientUploadID: Data(repeating: 5, count: 16)))
  }

  @Test("a server without piece support gets whole parts")
  func wholePartsWithoutGranularity() async throws {
    let body = pattern(524_288 * 2)
    let source = try sourceFile(body)
    defer { try? FileManager.default.removeItem(at: source) }
    let server = PieceServerMock(body: body, granularity: nil)
    let coordinator = DurableUploadCoordinator(transport: server, staging: PieceStaging(), ownerScope: { "owner" })
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:whole", fileURL: source, fileName: "a.bin", mimeType: "application/octet-stream",
      kind: .document
    ), progress: { _, _ in })
    #expect(await server.saves.allSatisfy { $0.offset == nil && $0.length == 524_288 })
  }
}
