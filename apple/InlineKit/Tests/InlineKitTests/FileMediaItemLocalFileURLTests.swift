import Foundation
import Testing

@testable import InlineKit

@Suite("FileMediaItem Local URL")
struct FileMediaItemLocalFileURLTests {
  @Test("Resolves local photo URL in photos cache directory")
  func resolvesPhotoLocalURL() {
    let photo = Photo(id: 1, photoId: 1, date: Date(timeIntervalSince1970: 0), format: .jpeg)
    let size = PhotoSize(id: 11, photoId: 1, type: "f", localPath: "photo-1.jpg")
    let item = FileMediaItem.photo(PhotoInfo(photo: photo, sizes: [size]))

    let url = item.localFileURL()

    #expect(url?.lastPathComponent == "photo-1.jpg")
    #expect(url?.path.contains("/Photos/") == true)
  }

  @Test("Resolves local video URL in videos cache directory")
  func resolvesVideoLocalURL() {
    let video = Video(
      id: 2,
      videoId: 2,
      date: Date(timeIntervalSince1970: 0),
      width: 100,
      height: 100,
      duration: 1,
      size: 128,
      thumbnailPhotoId: nil,
      cdnUrl: nil,
      localPath: "video-1.mp4"
    )
    let item = FileMediaItem.video(VideoInfo(video: video))

    let url = item.localFileURL()

    #expect(url?.lastPathComponent == "video-1.mp4")
    #expect(url?.path.contains("/Videos/") == true)
  }

  @Test("Resolves local document URL in documents cache directory")
  func resolvesDocumentLocalURL() {
    let document = Document(
      id: 3,
      documentId: 3,
      date: Date(timeIntervalSince1970: 0),
      fileName: "guide.pdf",
      mimeType: "application/pdf",
      size: 512,
      cdnUrl: nil,
      localPath: "doc-1-guide.pdf",
      thumbnailPhotoId: nil
    )
    let item = FileMediaItem.document(DocumentInfo(document: document))

    let url = item.localFileURL()

    #expect(url?.lastPathComponent == "doc-1-guide.pdf")
    #expect(url?.path.contains("/Documents/") == true)
  }

  @Test("Uses best photo size local path when available")
  func usesBestPhotoSizePath() {
    let photo = Photo(id: 10, photoId: 10, date: Date(timeIntervalSince1970: 0), format: .jpeg)
    let smaller = PhotoSize(id: 101, photoId: 10, type: "b", localPath: nil)
    let larger = PhotoSize(id: 102, photoId: 10, type: "f", localPath: "best.jpg")
    let item = FileMediaItem.photo(PhotoInfo(photo: photo, sizes: [smaller, larger]))

    let url = item.localFileURL()

    #expect(url?.lastPathComponent == "best.jpg")
  }

  @Test("Returns nil when local path is unavailable")
  func returnsNilWithoutLocalPath() {
    let document = Document(
      id: 4,
      documentId: 4,
      date: Date(timeIntervalSince1970: 0),
      fileName: "remote.pdf",
      mimeType: "application/pdf",
      size: 512,
      cdnUrl: "https://cdn.example.com/remote.pdf",
      localPath: nil,
      thumbnailPhotoId: nil
    )
    let item = FileMediaItem.document(DocumentInfo(document: document))

    #expect(item.localFileURL() == nil)
  }
}
