import Foundation

/// A ready image at one position in the currently rendered rich content.
/// The same photo may occur more than once; its photo ID is not an occurrence ID.
public struct BlockImageOccurrence: Hashable, Sendable {
  public let path: BlockContentPath
  public let photo: PhotoInfo

  public init(path: BlockContentPath, photo: PhotoInfo) {
    self.path = path
    self.photo = photo
  }
}

/// A short-lived value projection made when an image is opened. The native
/// viewer owns presentation; this value only preserves selection and identity.
public struct BlockImageGallery: Sendable {
  public struct Item: Sendable {
    /// Opaque, local to this gallery. Never send or persist it as a photo ID.
    public let occurrenceID: Int64
    public let image: BlockImageOccurrence
    public let url: URL
  }

  public let items: [Item]
  public let initialIndex: Int
  private let sourceImages: [BlockImageOccurrence]

  public init?(
    images: [BlockImageOccurrence],
    selectedPath: BlockContentPath,
    selectedPhotoID: Int64,
    resolveURL: (PhotoInfo) -> URL?
  ) {
    guard Set(images.map(\.path)).count == images.count,
          images.contains(where: { $0.path == selectedPath && $0.photo.id == selectedPhotoID })
    else { return nil }

    var items: [Item] = []
    for image in images {
      guard image.photo.id > 0, let url = resolveURL(image.photo) else { continue }
      guard url.isFileURL || (["https", "http"].contains(url.scheme?.lowercased() ?? "")
        && url.host?.isEmpty == false)
      else { continue }
      items.append(Item(occurrenceID: Int64(items.count + 1), image: image, url: url))
    }
    // Never substitute index zero if the tapped image cannot be opened.
    guard let index = items.firstIndex(where: {
      $0.image.path == selectedPath && $0.image.photo.id == selectedPhotoID
    }) else { return nil }
    self.items = items
    initialIndex = index
    sourceImages = images
  }

  /// Resolve a return-animation target against the current rendered snapshot.
  /// Exact occurrence topology permits duplicates; changed topology permits only
  /// a photo that occurs once in both snapshots. Missing/ambiguous targets fade.
  public func sourcePath(for occurrenceID: Int64, in current: [BlockImageOccurrence]) -> BlockContentPath? {
    guard let selected = items.first(where: { $0.occurrenceID == occurrenceID })?.image,
          Set(current.map(\.path)).count == current.count
    else { return nil }
    if sourceImages.count == current.count,
       zip(sourceImages, current).allSatisfy({ $0.path == $1.path && $0.photo.id == $1.photo.id })
    {
      return selected.path
    }
    let oldMatches = sourceImages.filter { $0.photo.id == selected.photo.id }
    let matches = current.filter { $0.photo.id == selected.photo.id }
    guard oldMatches.count == 1, matches.count == 1 else { return nil }
    return matches[0].path
  }

  /// Quick Look can expose only materialized local files. As neighbors finish,
  /// retain occurrence order and the current page rather than its old array index.
  public func localProjection(
    urlsByOccurrence: [Int64: URL], selectedOccurrenceID: Int64
  ) -> (items: [Item], selectedIndex: Int)? {
    let resolved = items.compactMap { item -> Item? in
      guard let url = urlsByOccurrence[item.occurrenceID], url.isFileURL else { return nil }
      return Item(occurrenceID: item.occurrenceID, image: item.image, url: url)
    }
    guard let index = resolved.firstIndex(where: { $0.occurrenceID == selectedOccurrenceID }) else { return nil }
    return (resolved, index)
  }
}
