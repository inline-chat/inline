import Foundation
import InlineProtocol
import Testing
@testable import Auth
@testable import InlineKit

private enum SimulatedUploadFailure: Error {
  case responseLost
}

private actor UploadRPCMock: NativeUploadRPCTransport {
  enum PartFailureMode {
    case afterAcceptance
    case beforeAcceptanceOnce
  }

  private let partFailureMode: PartFailureMode
  private let partSize: UInt32
  private let partCount: UInt32
  private let createResponsesLost: Int
  private let finishFailure: UploadFailure?
  private let emptyMissing: Bool
  private var accepted = false
  private var createAttempts = 0
  private var createUploadIDs: [Data] = []
  private var saveAttempts = 0
  private(set) var methods: [InlineProtocol.Method] = []

  init(
    partFailureMode: PartFailureMode = .afterAcceptance,
    partSize: UInt32 = 524_288,
    partCount: UInt32 = 1,
    createResponsesLost: Int = 0,
    finishFailure: UploadFailure? = nil,
    emptyMissing: Bool = false
  ) {
    self.partFailureMode = partFailureMode
    self.partSize = partSize
    self.partCount = partCount
    self.createResponsesLost = createResponsesLost
    self.finishFailure = finishFailure
    self.emptyMissing = emptyMissing
  }

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    methods.append(method)
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      createAttempts += 1
      createUploadIDs.append(create.clientUploadID)
      #expect(create.byteCount == 3)
      #expect(create.sha256.count == 32)
      if createAttempts <= createResponsesLost {
        throw SimulatedUploadFailure.responseLost
      }
      var result = CreateUploadResult()
      result.uploadID = Data(repeating: 7, count: 16)
      result.partSize = partSize
      result.partCount = partCount
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      #expect(save.partIndex == 0)
      #expect(save.data == Data([1, 2, 3]))
      saveAttempts += 1
      if partFailureMode == .beforeAcceptanceOnce, saveAttempts == 1 {
        throw SimulatedUploadFailure.responseLost
      }
      accepted = true
      if partFailureMode == .afterAcceptance {
        throw SimulatedUploadFailure.responseLost
      }
      return .saveUploadPart(SaveUploadPartResult())
    case (.getUploadState, .getUploadState):
      var state = GetUploadStateResult()
      state.status = .uploading
      state.acceptedParts = accepted ? [0] : []
      return .getUploadState(state)
    case (.finishUpload, .finishUpload):
      if emptyMissing {
        var finish = FinishUploadResult()
        finish.missing = UploadMissingParts()
        return .finishUpload(finish)
      }
      if let finishFailure {
        var finish = FinishUploadResult()
        finish.failed = finishFailure
        return .finishUpload(finish)
      }
      var photo = Photo()
      photo.id = 77
      var complete = UploadComplete()
      complete.fileUniqueID = "INP_native"
      complete.photo = photo
      var finish = FinishUploadResult()
      finish.complete = complete
      return .finishUpload(finish)
    case (.cancelUpload, .cancelUpload):
      var result = CancelUploadResult()
      result.canceled = true
      return .cancelUpload(result)
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }

  func calledMethods() -> [InlineProtocol.Method] { methods }
  func createdUploadIDs() -> [Data] { createUploadIDs }
}

private actor FinishResponseLostUploadRPCMock: NativeUploadRPCTransport {
  enum ReconciliationMode {
    case complete
    case uploading
    case processingThenComplete
  }

  private let reconciliationMode: ReconciliationMode
  private(set) var methods: [InlineProtocol.Method] = []
  private var finishCommitted = false
  private var finishAttempts = 0

  init(reconciliationMode: ReconciliationMode = .complete) {
    self.reconciliationMode = reconciliationMode
  }

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    methods.append(method)
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      var result = CreateUploadResult()
      result.uploadID = create.clientUploadID
      result.partSize = 524_288
      result.partCount = 1
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      #expect(save.partIndex == 0)
      #expect(save.data == Data([1, 2, 3]))
      return .saveUploadPart(SaveUploadPartResult())
    case (.finishUpload, .finishUpload):
      finishAttempts += 1
      if reconciliationMode == .processingThenComplete, finishAttempts > 1 {
        var photo = Photo()
        photo.id = 79
        var complete = UploadComplete()
        complete.fileUniqueID = "INP_finish_replayed"
        complete.photo = photo
        var finish = FinishUploadResult()
        finish.complete = complete
        return .finishUpload(finish)
      }
      finishCommitted = true
      throw SimulatedUploadFailure.responseLost
    case (.getUploadState, .getUploadState):
      #expect(finishCommitted)
      if reconciliationMode == .uploading {
        var state = GetUploadStateResult()
        state.status = .uploading
        state.acceptedParts = [0]
        return .getUploadState(state)
      }
      if reconciliationMode == .processingThenComplete {
        var state = GetUploadStateResult()
        state.status = .processing
        state.acceptedParts = [0]
        return .getUploadState(state)
      }
      var photo = Photo()
      photo.id = 78
      var complete = UploadComplete()
      complete.fileUniqueID = "INP_finish_reconciled"
      complete.photo = photo
      var state = GetUploadStateResult()
      state.status = .complete
      state.acceptedParts = [0]
      state.complete = complete
      return .getUploadState(state)
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }

  func calledMethods() -> [InlineProtocol.Method] { methods }
}

private actor PassthroughUploadStaging: NativeUploadStaging {
  private var discarded = false
  func stage(logicalID _: String, sourceURL: URL) -> URL { sourceURL }
  func discard(logicalID _: String) { discarded = true }
  func wasDiscarded() -> Bool { discarded }
}

private actor CancelingUploadStaging: NativeUploadStaging {
  private var discarded = false

  func stage(logicalID _: String, sourceURL: URL) -> URL {
    withUnsafeCurrentTask { $0?.cancel() }
    return sourceURL
  }

  func discard(logicalID _: String) { discarded = true }
  func wasDiscarded() -> Bool { discarded }
}

private actor BlockingPartUploadRPCMock: NativeUploadRPCTransport {
  private var createdUploads = 0
  private var startedParts: [UInt8] = []
  private var partContinuations: [CheckedContinuation<Void, Never>] = []
  private var finishedUploads = 0
  private var cancelledUploads = 0

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      createdUploads += 1
      var result = CreateUploadResult()
      result.uploadID = create.clientUploadID
      result.partSize = 524_288
      result.partCount = 1
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      startedParts.append(try #require(save.data.first))
      await withCheckedContinuation { continuation in
        partContinuations.append(continuation)
      }
      var result = SaveUploadPartResult()
      result.alreadyPresent = false
      return .saveUploadPart(result)
    case (.finishUpload, .finishUpload):
      finishedUploads += 1
      var photo = Photo()
      photo.id = 88
      var complete = UploadComplete()
      complete.fileUniqueID = "INP_slot"
      complete.photo = photo
      var finish = FinishUploadResult()
      finish.complete = complete
      return .finishUpload(finish)
    case (.cancelUpload, .cancelUpload):
      cancelledUploads += 1
      return .cancelUpload(CancelUploadResult())
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }

  func createCount() -> Int { createdUploads }
  func startedValues() -> [UInt8] { startedParts }
  func finishCount() -> Int { finishedUploads }
  func cancelCount() -> Int { cancelledUploads }

  func releaseAllParts() {
    let continuations = partContinuations
    partContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private actor CompletionProbe {
  private var completed = false
  func markCompleted() { completed = true }
  func isCompleted() -> Bool { completed }
}

private actor PipelinedPartUploadRPCMock: NativeUploadRPCTransport {
  private var startedParts: [UInt32] = []
  private var completedParts: Set<UInt32> = []
  private var partContinuations: [UInt32: CheckedContinuation<Void, Never>] = [:]
  private var finishCalls = 0

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      #expect(create.byteCount == 4 * 524_288)
      var result = CreateUploadResult()
      result.uploadID = create.clientUploadID
      result.partSize = 524_288
      result.partCount = 4
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      startedParts.append(save.partIndex)
      await withCheckedContinuation { continuation in
        partContinuations[save.partIndex] = continuation
      }
      completedParts.insert(save.partIndex)
      return .saveUploadPart(SaveUploadPartResult())
    case (.finishUpload, .finishUpload):
      finishCalls += 1
      #expect(completedParts == Set(0 ..< 4))
      var complete = UploadComplete()
      complete.fileUniqueID = "INP_pipeline"
      var finish = FinishUploadResult()
      finish.complete = complete
      return .finishUpload(finish)
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }

  func started() -> [UInt32] { startedParts }
  func finishCount() -> Int { finishCalls }

  func release(_ partIndex: UInt32) {
    partContinuations.removeValue(forKey: partIndex)?.resume()
  }
}

private final class UploadProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int64] = []

  func append(_ value: Int64) {
    lock.withLock { values.append(value) }
  }

  func recordedValues() -> [Int64] {
    lock.withLock { values }
  }
}

private enum UploadAccountFenceError: Error { case changed }

private final class TestUploadAccountFence: NativeUploadAccountFencing, @unchecked Sendable {
  private let lock = NSLock()
  private var current = AuthAccountMutationToken(generation: 1, userID: 7)

  func beginUploadAccountFence() throws -> AuthAccountMutationToken { lock.withLock { current } }
  func validateUploadAccountFence(_ token: AuthAccountMutationToken) throws {
    if lock.withLock({ token != current }) { throw UploadAccountFenceError.changed }
  }
  func switchAccount() {
    lock.withLock {
      current = AuthAccountMutationToken(generation: current.generation + 1, userID: 8)
    }
  }
}

private actor BlockingUploadStaging: NativeUploadStaging {
  let entered = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  private var discarded = false

  func stage(logicalID _: String, sourceURL: URL) async -> URL {
    entered.continuation.yield()
    for await _ in release.stream { break }
    return sourceURL
  }
  func discard(logicalID _: String) { discarded = true }
  func wasDiscarded() -> Bool { discarded }
}

private actor AccountFencedUploadRPCMock: AccountBoundNativeUploadRPCTransport {
  let fence: TestUploadAccountFence
  private var methods: [InlineProtocol.Method] = []

  init(fence: TestUploadAccountFence) { self.fence = fence }

  func callUploadRPC(
    method _: InlineProtocol.Method,
    input _: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    Issue.record("Account-fenced upload used the unfenced RPC overload")
    throw UploadAccountFenceError.changed
  }

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?,
    accountToken: AuthAccountMutationToken
  ) async throws -> RpcResult.OneOf_Result? {
    try fence.validateUploadAccountFence(accountToken)
    methods.append(method)
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      var result = CreateUploadResult()
      result.uploadID = create.clientUploadID
      result.partSize = 524_288
      result.partCount = UInt32((create.byteCount + 524_287) / 524_288)
      return .createUpload(result)
    case (.saveUploadPart, .saveUploadPart):
      fence.switchAccount()
      return .saveUploadPart(SaveUploadPartResult())
    case (.cancelUpload, .cancelUpload):
      return .cancelUpload(CancelUploadResult())
    default:
      Issue.record("Unexpected account-fenced RPC \(method)")
      return nil
    }
  }

  func calledMethods() -> [InlineProtocol.Method] { methods }
}

@Suite("Native upload")
struct NativeUploadTests {
  @Test("rejects an over-limit file before staging")
  func rejectsOverLimitBeforeStaging() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-limit-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: source.path, contents: Data())
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: 20_000_001)
    try handle.close()
    defer { try? FileManager.default.removeItem(at: source) }
    let transport = UploadRPCMock()
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport, staging: staging, ownerScope: { "test-owner" }
    )
    await #expect(throws: NativeMediaUploadError.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "voice:large", fileURL: source, fileName: "large.ogg",
        mimeType: "audio/ogg", kind: .voice
      ), progress: { _, _ in })
    }
    #expect(await transport.calledMethods().isEmpty)
    #expect(!(await staging.wasDiscarded()))
  }

  @Test("account switch while staging is blocked performs no replacement-account RPC")
  func accountSwitchDuringStaging() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-account-stage-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let fence = TestUploadAccountFence()
    let transport = AccountFencedUploadRPCMock(fence: fence)
    let staging = BlockingUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport, staging: staging, accountFence: fence, ownerScope: { "test-owner" }
    )
    let upload = Task {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "document:account-stage", fileURL: source, fileName: "proof.bin",
        mimeType: "application/octet-stream", kind: .document
      ), progress: { _, _ in })
    }
    for await _ in await staging.entered.stream { break }
    fence.switchAccount()
    await staging.release.continuation.finish()
    await #expect(throws: UploadAccountFenceError.self) { try await upload.value }
    #expect(await transport.calledMethods().isEmpty)
    #expect(await staging.wasDiscarded())
  }

  @Test("account switch between parts stops RPCs, cleans staging, and emits no late progress")
  func accountSwitchBetweenParts() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-account-parts-\(UUID().uuidString)")
    try Data(repeating: 1, count: 2 * 524_288).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let fence = TestUploadAccountFence()
    let transport = AccountFencedUploadRPCMock(fence: fence)
    let staging = PassthroughUploadStaging()
    let progress = UploadProgressRecorder()
    let coordinator = DurableUploadCoordinator(
      transport: transport, staging: staging, accountFence: fence, ownerScope: { "test-owner" }
    )
    await #expect(throws: UploadAccountFenceError.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "document:account-parts", fileURL: source, fileName: "proof.bin",
        mimeType: "application/octet-stream", kind: .document
      ), progress: { accepted, _ in progress.append(accepted) })
    }
    #expect(await transport.calledMethods() == [.createUpload, .saveUploadPart])
    #expect(progress.recordedValues() == [0])
    #expect(await staging.wasDiscarded())
  }

  @Test("rejects empty missing-parts result instead of looping finish")
  func emptyMissingPartsIsTerminal() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-empty-missing-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let transport = UploadRPCMock(emptyMissing: true)
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(transport: transport, staging: staging, ownerScope: { "test-owner" })
    await #expect(throws: NativeMediaUploadError.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:empty-missing", fileURL: source, fileName: "photo.jpg", mimeType: "image/jpeg", kind: .photo
      ), progress: { _, _ in })
    }
    #expect(await transport.calledMethods().filter { $0 == .finishUpload }.count == 1)
    #expect(await transport.calledMethods().last == .cancelUpload)
    #expect(await staging.wasDiscarded())
  }

  @Test("discards staging when local hashing fails before create")
  func failedHashDiscardsStaging() async {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-missing-\(UUID().uuidString)")
    let transport = UploadRPCMock()
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(transport: transport, staging: staging, ownerScope: { "test-owner" })
    do {
      _ = try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:missing", fileURL: missing, fileName: "photo.jpg", mimeType: "image/jpeg", kind: .photo
      ), progress: { _, _ in })
      Issue.record("Missing staged body was accepted")
    } catch {
      #expect(await staging.wasDiscarded())
      #expect(await transport.calledMethods().isEmpty)
    }
  }

  @Test(
    "rejects invalid geometry before arithmetic or transfer",
    arguments: [UInt32(0), UInt32(1), UInt32(16 * 1_048_576), UInt32.max]
  )
  func rejectsInvalidPartSize(partSize: UInt32) async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-geometry-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let transport = UploadRPCMock(partSize: partSize)
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: staging,
      ownerScope: { "test-owner" }
    )
    await #expect(throws: NativeMediaUploadError.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:geometry", fileURL: source, fileName: "photo.jpg", mimeType: "image/jpeg", kind: .photo
      ), progress: { _, _ in })
    }
    #expect(await transport.calledMethods() == [.createUpload, .cancelUpload])
    #expect(await staging.wasDiscarded())
  }

  @Test("rejects more than one thousand parts before transfer")
  func rejectsExcessivePartCount() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-part-count-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let transport = UploadRPCMock(partCount: 1_001)
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: staging,
      ownerScope: { "test-owner" }
    )
    await #expect(throws: NativeMediaUploadError.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:part-count",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ), progress: { _, _ in })
    }
    #expect(await transport.calledMethods() == [.createUpload, .cancelUpload])
    #expect(await staging.wasDiscarded())
  }

  @Test("discards terminal rejection staging but preserves retryable failures", arguments: [false, true])
  func rejectedUploadCleanup(retryable: Bool) async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-rejection-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    var failure = UploadFailure()
    failure.code = .uploadFailureInvalidMedia
    failure.retryable = retryable
    let transport = UploadRPCMock(finishFailure: failure)
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(transport: transport, staging: staging, ownerScope: { "test-owner" })
    await #expect(throws: NativeMediaUploadError.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:rejection", fileURL: source, fileName: "photo.jpg", mimeType: "image/jpeg", kind: .photo
      ), progress: { _, _ in })
    }
    #expect(await staging.wasDiscarded() == !retryable)
    #expect(await transport.calledMethods().contains(.cancelUpload) == !retryable)
  }

  @Test("bounds authenticated processing retry hints")
  func boundsProcessingRetryHints() {
    #expect(boundedUploadProcessingRetrySeconds(0) == 1)
    #expect(boundedUploadProcessingRetrySeconds(2) == 2)
    #expect(boundedUploadProcessingRetrySeconds(UInt32.max) == 30)
  }

  @Test("reconciles a response lost after the server accepts a part")
  func reconcilesLostSaveResponse() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-test-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = UploadRPCMock()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      ownerScope: { "test-owner" }
    )
    let complete = try await coordinator.upload(
      NativeMediaUploadRequest(
        logicalID: "photo:-1",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ),
      progress: { _, _ in }
    )

    #expect(complete.fileUniqueID == "INP_native")
    #expect(complete.photo.id == 77)
    #expect(await transport.calledMethods() == [
      .createUpload,
      .saveUploadPart,
      .getUploadState,
      .finishUpload,
    ])
  }

  @Test("replays create once with the same stable client upload ID after a lost response")
  func replaysLostCreateResponse() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-create-replay-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let transport = UploadRPCMock(createResponsesLost: 1)
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: staging,
      ownerScope: { "test-owner" }
    )

    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "photo:create-replay",
      fileURL: source,
      fileName: "photo.jpg",
      mimeType: "image/jpeg",
      kind: .photo
    ), progress: { _, _ in })

    #expect(complete.fileUniqueID == "INP_native")
    let clientUploadIDs = await transport.createdUploadIDs()
    #expect(clientUploadIDs.count == 2)
    #expect(clientUploadIDs[0] == clientUploadIDs[1])
    let methods = await transport.calledMethods()
    #expect(Array(methods.prefix(2)) == [.createUpload, .createUpload])
    #expect(await staging.wasDiscarded())
  }

  @Test("preserves staging when both bounded create responses are lost")
  func preservesStagingAfterAmbiguousCreate() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-create-ambiguous-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let transport = UploadRPCMock(createResponsesLost: 2)
    let staging = PassthroughUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: staging,
      ownerScope: { "test-owner" }
    )

    await #expect(throws: SimulatedUploadFailure.self) {
      try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "photo:create-ambiguous",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ), progress: { _, _ in })
    }

    #expect(await transport.calledMethods() == [.createUpload, .createUpload])
    let clientUploadIDs = await transport.createdUploadIDs()
    #expect(clientUploadIDs.count == 2)
    #expect(clientUploadIDs[0] == clientUploadIDs[1])
    #expect(!(await staging.wasDiscarded()))
  }

  @Test("replays a part once when authoritative state says it is missing")
  func replaysMissingPartOnce() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-replay-test-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = UploadRPCMock(partFailureMode: .beforeAcceptanceOnce)
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: PassthroughUploadStaging(),
      ownerScope: { "test-owner" }
    )
    let complete = try await coordinator.upload(
      NativeMediaUploadRequest(
        logicalID: "photo:replay",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ),
      progress: { _, _ in }
    )

    #expect(complete.fileUniqueID == "INP_native")
    #expect(await transport.calledMethods() == [
      .createUpload,
      .saveUploadPart,
      .getUploadState,
      .saveUploadPart,
      .finishUpload,
    ])
  }

  @Test("reconciles a finish response lost after finalization commits")
  func reconcilesLostFinishResponse() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-finish-test-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = FinishResponseLostUploadRPCMock()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: PassthroughUploadStaging(),
      ownerScope: { "test-owner" }
    )
    let complete = try await coordinator.upload(
      NativeMediaUploadRequest(
        logicalID: "photo:finish-lost",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ),
      progress: { _, _ in }
    )

    #expect(complete.fileUniqueID == "INP_finish_reconciled")
    #expect(complete.photo.id == 78)
    #expect(await transport.calledMethods() == [
      .createUpload,
      .saveUploadPart,
      .finishUpload,
      .getUploadState,
    ])
  }

  @Test("replays finish after a lost response reports processing")
  func replaysFinishAfterProcessingProbe() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-processing-replay-test-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = FinishResponseLostUploadRPCMock(reconciliationMode: .processingThenComplete)
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: PassthroughUploadStaging(),
      ownerScope: { "test-owner" }
    )
    let complete = try await coordinator.upload(
      NativeMediaUploadRequest(
        logicalID: "photo:processing-replay",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ),
      progress: { _, _ in }
    )

    #expect(complete.fileUniqueID == "INP_finish_replayed")
    #expect(complete.photo.id == 79)
    #expect(await transport.calledMethods() == [
      .createUpload,
      .saveUploadPart,
      .finishUpload,
      .getUploadState,
      .finishUpload,
    ])
  }

  @Test("bounds ambiguous finish retries without new accepted parts")
  func boundsAmbiguousFinishRetries() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-finish-bound-test-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = FinishResponseLostUploadRPCMock(reconciliationMode: .uploading)
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: PassthroughUploadStaging(),
      ownerScope: { "test-owner" }
    )
    await #expect(throws: SimulatedUploadFailure.self) {
      try await coordinator.upload(
        NativeMediaUploadRequest(
          logicalID: "photo:finish-bound",
          fileURL: source,
          fileName: "photo.jpg",
          mimeType: "image/jpeg",
          kind: .photo
        ),
        progress: { _, _ in }
      )
    }

    let methods = await transport.calledMethods()
    #expect(methods.count(where: { $0 == .finishUpload }) == 4)
    #expect(methods.count(where: { $0 == .getUploadState }) == 3)
  }

  @Test("stages an immutable source and cleans it up after completion")
  func stagesImmutableSource() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-store-\(UUID().uuidString)")
    let source = directory.appendingPathComponent("source")
    let stagingRoot = directory.appendingPathComponent("staged")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileNativeUploadStagingStore(root: stagingRoot)
    let staged = try await store.stage(logicalID: "test-owner:photo:-2", sourceURL: source)
    try Data([9, 9, 9]).write(to: source, options: .atomic)
    #expect(try Data(contentsOf: staged) == Data([1, 2, 3]))

    let coordinator = DurableUploadCoordinator(
      transport: UploadRPCMock(),
      staging: store,
      ownerScope: { "test-owner" }
    )
    _ = try await coordinator.upload(
      NativeMediaUploadRequest(
        logicalID: "photo:-2",
        fileURL: source,
        fileName: "photo.jpg",
        mimeType: "image/jpeg",
        kind: .photo
      ),
      progress: { _, _ in }
    )
    #expect(FileManager.default.fileExists(atPath: staged.path) == false)
  }

  @Test("discards unaddressable staging when canceled before create")
  func cancelsAfterStaging() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-preflight-cancel-test-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = UploadRPCMock()
    let staging = CancelingUploadStaging()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: staging,
      ownerScope: { "test-owner" }
    )
    let upload = Task {
      try await coordinator.upload(
        NativeMediaUploadRequest(
          logicalID: "photo:preflight-cancel",
          fileURL: source,
          fileName: "photo.jpg",
          mimeType: "image/jpeg",
          kind: .photo
        ),
        progress: { _, _ in }
      )
    }

    let result = await upload.result
    guard case let .failure(error) = result else {
      Issue.record("Expected preflight cancellation")
      return
    }
    #expect(error is CancellationError)
    #expect(await staging.wasDiscarded())
    #expect(await transport.calledMethods().isEmpty)
  }

  @Test("cancels a transfer waiting for the global part limit without leaking a slot")
  func cancelsWaitingPartTransfer() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-slots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let transport = BlockingPartUploadRPCMock()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: PassthroughUploadStaging(),
      ownerScope: { "test-owner" }
    )
    let sources = try (1 ... 4).map { value in
      let url = directory.appendingPathComponent("source-\(value)")
      try Data([UInt8(value)]).write(to: url)
      return url
    }
    let makeTask: @Sendable (Int) -> Task<UploadComplete, Error> = { index in
      let source = sources[index]
      return Task {
        try await coordinator.upload(
          NativeMediaUploadRequest(
            logicalID: "photo:slot-\(index)",
            fileURL: source,
            fileName: "photo.jpg",
            mimeType: "image/jpeg",
            kind: .photo
          ),
          progress: { _, _ in }
        )
      }
    }

    var tasks: [Task<UploadComplete, Error>] = []
    for index in 0 ..< 3 {
      tasks.append(makeTask(index))
      for _ in 0 ..< 200 {
        if (await transport.startedValues()).contains(UInt8(index + 1)) { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect((await transport.startedValues()).contains(UInt8(index + 1)))
    }
    #expect(await transport.startedValues().count == 3)

    let fourthTask = makeTask(3)
    tasks.append(fourthTask)
    for _ in 0 ..< 200 {
      if await transport.createCount() == 4 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await transport.createCount() == 4)
    #expect(await transport.startedValues().count == 3)
    for _ in 0 ..< 10 { await Task.yield() }

    let fourthCompletion = CompletionProbe()
    let fourthResult = Task {
      let result = await fourthTask.result
      await fourthCompletion.markCompleted()
      return result
    }
    fourthTask.cancel()
    for _ in 0 ..< 200 where !(await fourthCompletion.isCompleted()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fourthCompletion.isCompleted())

    await transport.releaseAllParts()
    for task in tasks.prefix(3) {
      _ = try await task.value
    }
    let result = await fourthResult.value
    guard case .failure(let error) = result else {
      Issue.record("Expected the waiting upload to be cancelled")
      return
    }
    #expect(error is CancellationError)
    #expect(!(await transport.startedValues()).contains(4))
    #expect(await transport.cancelCount() == 1)
    #expect(await transport.finishCount() == 3)
  }

  @Test("pipelines two parts per upload, refills out of order, and finishes after every part")
  func pipelinesParts() async throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-pipeline-\(UUID().uuidString)")
    try Data(repeating: 7, count: 4 * 524_288).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let transport = PipelinedPartUploadRPCMock()
    let progress = UploadProgressRecorder()
    let coordinator = DurableUploadCoordinator(
      transport: transport,
      staging: PassthroughUploadStaging(),
      ownerScope: { "test-owner" }
    )
    let upload = Task {
      try await coordinator.upload(
        NativeMediaUploadRequest(
          logicalID: "document:pipeline",
          fileURL: source,
          fileName: "proof.bin",
          mimeType: "application/octet-stream",
          kind: .document
        ),
        progress: { accepted, _ in progress.append(accepted) }
      )
    }

    for _ in 0 ..< 200 {
      if await transport.started().count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(Set(await transport.started()) == Set(0 ..< 2))
    #expect(await transport.finishCount() == 0)

    await transport.release(1)
    for _ in 0 ..< 200 {
      if await transport.started().count == 3 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(Set(await transport.started()) == Set(0 ..< 3))
    #expect(await transport.finishCount() == 0)

    await transport.release(2)
    for _ in 0 ..< 200 {
      if await transport.started().count == 4 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(Set(await transport.started()) == Set(0 ..< 4))
    #expect(await transport.finishCount() == 0)

    await transport.release(3)
    await transport.release(0)
    let complete = try await upload.value
    #expect(complete.fileUniqueID == "INP_pipeline")
    #expect(await transport.finishCount() == 1)
    #expect(progress.recordedValues() == (0 ... 4).map { Int64($0 * 524_288) })
  }
}
