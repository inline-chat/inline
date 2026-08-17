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
}
