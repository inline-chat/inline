import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite("Send Message Upload Start Policy")
struct SendMessageUploadStartPolicyTests {
  @Test("swallows upload already in progress errors so send can join the existing upload")
  func swallowsUploadAlreadyInProgressError() async throws {
    await #expect(throws: Never.self) {
      try await SendMessageUploadCoordinator.beginOrJoinUpload {
        throw FileUploadError.uploadAlreadyInProgress
      }
    }
  }

  @Test("rethrows unrelated upload start errors")
  func rethrowsUnrelatedUploadStartErrors() async throws {
    await #expect(throws: FileUploadError.invalidDocument) {
      try await SendMessageUploadCoordinator.beginOrJoinUpload {
        throw FileUploadError.invalidDocument
      }
    }
  }

  @Test("resolves video local id from temporary video id when local id is missing")
  func resolvesVideoLocalIdFromVideoIdLookup() async throws {
    let temporaryVideoId = -Int64.random(in: 1 ... (Int64.max / 2))
    let localPath = "test-\(UUID().uuidString).mp4"

    let storedVideo = try await AppDatabase.shared.dbWriter.write { db in
      let video = Video(
        videoId: temporaryVideoId,
        date: Date(),
        width: 16,
        height: 16,
        duration: 1,
        size: 128,
        thumbnailPhotoId: nil,
        cdnUrl: nil,
        localPath: localPath
      )
      try video.insert(db)
      return video
    }

    let detachedVideo = Video(
      id: nil,
      videoId: storedVideo.videoId,
      date: storedVideo.date,
      width: storedVideo.width,
      height: storedVideo.height,
      duration: storedVideo.duration,
      size: storedVideo.size,
      thumbnailPhotoId: storedVideo.thumbnailPhotoId,
      cdnUrl: storedVideo.cdnUrl,
      localPath: storedVideo.localPath
    )

    let resolvedLocalId = try await FileUploader.shared.resolveLocalVideoId(for: detachedVideo)

    let expectedLocalId = try await AppDatabase.shared.dbWriter.read { db in
      try Video
        .filter(Column("videoId") == temporaryVideoId)
        .fetchOne(db)?
        .id
    }

    #expect(resolvedLocalId == expectedLocalId)
  }

  @Test("createLocalVideo returns a persisted local id that survives server id rewrites")
  func createLocalVideoReturnsPersistedLocalId() async throws {
    let video = try MediaHelpers.shared.createLocalVideo(
      width: 16,
      height: 16,
      duration: 1,
      size: 128,
      localPath: "test-\(UUID().uuidString).mp4"
    )

    let localId = try #require(video.id)

    try await AppDatabase.shared.dbWriter.write { db in
      try AppDatabase.updateVideoWithServerId(db, localVideo: video, serverId: Int64.random(in: 1 ... Int64.max))
    }

    let resolvedLocalId = try await FileUploader.shared.resolveLocalVideoId(for: video)
    #expect(resolvedLocalId == localId)
  }

  @Test("createLocalDocument returns a persisted local id")
  func createLocalDocumentReturnsPersistedLocalId() throws {
    let document = try MediaHelpers.shared.createLocalDocument(
      fileName: "test.txt",
      mimeType: "text/plain",
      size: 16
    )

    #expect(document.id != nil)
  }
}
