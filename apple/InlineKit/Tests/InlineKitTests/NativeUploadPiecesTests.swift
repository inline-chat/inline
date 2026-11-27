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
  private var received: [UInt32: Data] = [:]
  private var filled: [UInt32: Int] = [:]
  private(set) var saves: [Save] = []
  private(set) var methods: [InlineProtocol.Method] = []
  private(set) var inlineData: Data?

  init(body: Data, granularity: UInt32? = 16_384, rejectsPieces: Bool = false) {
    self.body = body
    self.granularity = granularity
    self.rejectsPieces = rejectsPieces
  }

  private var partCount: UInt32 { UInt32((body.count + 524_287) / 524_288) }

  private func partLength(_ index: UInt32) -> Int {
    min(524_288, body.count - Int(index) * 524_288)
  }

  private var acceptedParts: [UInt32] {
    (0 ..< partCount).filter { filled[$0] == partLength($0) }
  }

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    methods.append(method)
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      if create.hasInlineData { inlineData = create.inlineData }
      var result = CreateUploadResult()
      result.uploadID = Data(repeating: 9, count: 16)
      result.partSize = 524_288
      result.partCount = partCount
      if let granularity { result.pieceGranularity = granularity }
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      saves.append(Save(part: save.partIndex, offset: save.hasOffset ? save.offset : nil, length: save.data.count))
      if save.hasOffset, rejectsPieces { throw PieceRejected.oldServer }
      let offset = save.hasOffset ? Int(save.offset) : 0
      let start = Int(save.partIndex) * 524_288 + offset
      #expect(save.data == body.subdata(in: start ..< start + save.data.count))
      if let granularity, save.hasOffset {
        #expect(offset % Int(granularity) == 0)
      }
      var part = received[save.partIndex] ?? Data(count: partLength(save.partIndex))
      part.replaceSubrange(offset ..< offset + save.data.count, with: save.data)
      received[save.partIndex] = part
      filled[save.partIndex, default: 0] += save.data.count
      return .saveUploadPart(SaveUploadPartResult())
    case (.getUploadState, .getUploadState):
      var state = GetUploadStateResult()
      state.status = .uploading
      state.acceptedParts = acceptedParts
      return .getUploadState(state)
    case (.finishUpload, .finishUpload):
      var finish = FinishUploadResult()
      let missing = (0 ..< partCount).filter { !acceptedParts.contains($0) }
      if !missing.isEmpty {
        var parts = UploadMissingParts()
        parts.partIndices = missing
        finish.missing = parts
        return .finishUpload(finish)
      }
      let assembled = (0 ..< partCount).reduce(into: Data()) { $0.append(received[$1]!) }
      #expect(assembled == body)
      var complete = UploadComplete()
      complete.fileUniqueID = "IND_pieces"
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
