import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

private enum SimulatedUploadFailure: Error {
  case responseLost
}

private actor UploadRPCMock: NativeUploadRPCTransport {
  private var accepted = false
  private(set) var methods: [InlineProtocol.Method] = []

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    methods.append(method)
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      #expect(create.byteCount == 3)
      #expect(create.sha256.count == 32)
      var result = CreateUploadResult()
      result.uploadID = Data(repeating: 7, count: 16)
      result.partSize = 524_288
      result.partCount = 1
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      #expect(save.partIndex == 0)
      #expect(save.data == Data([1, 2, 3]))
      accepted = true
      throw SimulatedUploadFailure.responseLost
    case (.getUploadState, .getUploadState):
      var state = GetUploadStateResult()
      state.status = .uploading
      state.acceptedParts = accepted ? [0] : []
      return .getUploadState(state)
    case (.finishUpload, .finishUpload):
      var photo = Photo()
      photo.id = 77
      var complete = UploadComplete()
      complete.fileUniqueID = "INP_native"
      complete.photo = photo
      var finish = FinishUploadResult()
      finish.complete = complete
      return .finishUpload(finish)
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }

  func calledMethods() -> [InlineProtocol.Method] { methods }
}

private actor FinishResponseLostUploadRPCMock: NativeUploadRPCTransport {
  private(set) var methods: [InlineProtocol.Method] = []
  private var finishCommitted = false

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
      finishCommitted = true
      throw SimulatedUploadFailure.responseLost
    case (.getUploadState, .getUploadState):
      #expect(finishCommitted)
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
  func stage(logicalID _: String, sourceURL: URL) -> URL { sourceURL }
  func recordProgress(logicalID _: String, acceptedBytes _: Int64, totalBytes _: Int64) {}
  func discard(logicalID _: String) {}
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
      #expect(create.byteCount == 4)
      var result = CreateUploadResult()
      result.uploadID = create.clientUploadID
      result.partSize = 1
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

@Suite("Native upload")
struct NativeUploadTests {
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
    try Data([0, 1, 2, 3]).write(to: source)
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
    #expect(progress.recordedValues() == [0, 1, 2, 3, 4])
  }
}
