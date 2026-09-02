import Foundation
import Testing

@testable import InlineKit

@Suite("Rich image gallery selection")
struct BlockImageGalleryTests {
  @Test("duplicate photos retain separate pages and the tapped occurrence")
  func duplicates() throws {
    let images = [image(42, at: 0), image(7, at: 1), image(42, at: 2)]
    let gallery = try #require(make(images, selected: 2))
    #expect(gallery.items.map { $0.image.photo.id } == [42, 7, 42])
    #expect(Set(gallery.items.map(\.occurrenceID)).count == 3)
    #expect(gallery.initialIndex == 2)
    #expect(gallery.sourcePath(for: gallery.items[2].occurrenceID, in: images) == images[2].path)
  }

  @Test("unresolved neighbors do not shift the selected image to another photo")
  func unavailableNeighbor() throws {
    let images = [image(1, at: 0), image(2, at: 1), image(3, at: 2)]
    let gallery = try #require(make(images, selected: 2, missing: [1]))
    #expect(gallery.items.map { $0.image.photo.id } == [2, 3])
    #expect(gallery.initialIndex == 1)
    #expect(make(images, selected: 0, missing: [1]) == nil)
  }

  @Test("a stale selection must match both path and photo")
  func staleSelection() {
    let images = [image(1, at: 0), image(2, at: 1)]
    #expect(BlockImageGallery(images: images, selectedPath: images[0].path, selectedPhotoID: 2,
      resolveURL: url) == nil)
    #expect(BlockImageGallery(images: images, selectedPath: image(1, at: 5).path, selectedPhotoID: 1,
      resolveURL: url) == nil)
  }

  @Test("pending positions are represented by gaps, not by a ready-only ordinal")
  func pendingBeforeReady() throws {
    let path = BlockContentPath([.block(0), .albumImage(2)])
    let images = [BlockImageOccurrence(path: path, photo: photo(42))]
    let gallery = try #require(BlockImageGallery(images: images, selectedPath: path, selectedPhotoID: 42,
      resolveURL: url))
    #expect(gallery.initialIndex == 0)
    #expect(gallery.sourcePath(for: 1, in: images) == path)
  }

  @Test("unique images can move while the viewer is open")
  func uniqueMove() throws {
    let old = [image(1, at: 0), image(2, at: 1)]
    let gallery = try #require(make(old, selected: 1))
    let current = [image(3, at: 0), image(1, at: 1), image(2, at: 2)]
    #expect(gallery.sourcePath(for: gallery.items[1].occurrenceID, in: current) == current[2].path)
    #expect(gallery.sourcePath(for: gallery.items[1].occurrenceID, in: [image(1, at: 0)]) == nil)
  }

  @Test("changed duplicate topology never picks an arbitrary dismissal target")
  func ambiguousMove() throws {
    let old = [image(42, at: 0), image(42, at: 1)]
    let gallery = try #require(make(old, selected: 1))
    #expect(gallery.sourcePath(for: 2, in: [image(7, at: 0), image(42, at: 1), image(42, at: 2)]) == nil)
    #expect(gallery.sourcePath(for: 2, in: [image(42, at: 0)]) == nil)
    let unique = try #require(make([image(42, at: 0)], selected: 0))
    #expect(unique.sourcePath(for: 1, in: old) == nil)
  }

  @Test("invalid paths, IDs and non-media URLs cannot create a gallery")
  func invalidInputs() {
    let valid = image(42, at: 0)
    #expect(make([valid, valid], selected: 0) == nil)
    #expect(make([image(0, at: 0)], selected: 0) == nil)
    for value in ["relative/path", "javascript:alert(1)", "https:"] {
      #expect(BlockImageGallery(images: [valid], selectedPath: valid.path, selectedPhotoID: 42,
        resolveURL: { _ in URL(string: value) }) == nil)
    }
  }

  @Test("local gallery expansion preserves the selected occurrence, not its old index")
  func localExpansion() throws {
    let gallery = try #require(make([image(42, at: 0), image(7, at: 1), image(42, at: 2)], selected: 2))
    let file = URL(fileURLWithPath: "/tmp/gallery-42.jpg")
    let first = try #require(gallery.localProjection(urlsByOccurrence: [3: file], selectedOccurrenceID: 3))
    #expect(first.items.map(\.occurrenceID) == [3])
    #expect(first.selectedIndex == 0)
    let next = try #require(gallery.localProjection(urlsByOccurrence: [1: file, 3: file], selectedOccurrenceID: 3))
    #expect(next.items.map(\.occurrenceID) == [1, 3])
    #expect(next.selectedIndex == 1)
    #expect(next.items[1].image.path == gallery.items[2].image.path)
    // Navigating to an already loaded neighbor must survive subsequent downloads too.
    let all = try #require(gallery.localProjection(
      urlsByOccurrence: [1: file, 2: URL(fileURLWithPath: "/tmp/gallery-7.jpg"), 3: file],
      selectedOccurrenceID: 1))
    #expect(all.selectedIndex == 0)
    #expect(all.items.map(\.occurrenceID) == [1, 2, 3])
  }

  @Test("a local projection never exposes a remote URL or substitutes a missing selected file")
  func localOnly() throws {
    let gallery = try #require(make([image(1, at: 0), image(2, at: 1)], selected: 1))
    let urls = [Int64(1): URL(fileURLWithPath: "/tmp/gallery-1.jpg"), 2: URL(string: "https://example.com/2.jpg")!]
    #expect(gallery.localProjection(urlsByOccurrence: urls, selectedOccurrenceID: 2) == nil)
    let first = try #require(gallery.localProjection(urlsByOccurrence: urls, selectedOccurrenceID: 1))
    #expect(first.items.count == 1)
    #expect(gallery.localProjection(urlsByOccurrence: urls, selectedOccurrenceID: 99) == nil)
  }

  private func make(_ images: [BlockImageOccurrence], selected: Int, missing: Set<Int64> = []) -> BlockImageGallery? {
    BlockImageGallery(images: images, selectedPath: images[selected].path,
      selectedPhotoID: images[selected].photo.id, resolveURL: { missing.contains($0.id) ? nil : url($0) })
  }

  private func photo(_ id: Int64) -> PhotoInfo {
    PhotoInfo(photo: .init(photoId: id, date: Date(timeIntervalSince1970: 1), format: .jpeg))
  }

  private func image(_ id: Int64, at index: Int) -> BlockImageOccurrence {
    .init(path: .init([.block(index)]), photo: photo(id))
  }

  private func url(_ photo: PhotoInfo) -> URL? {
    URL(string: "https://example.com/\(photo.id).jpg")
  }
}
