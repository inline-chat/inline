import Foundation
import InlineProtocol

/// A local structural path. It deliberately never crosses the protocol or
/// database boundary and gives renderers a cheap same-position reuse hint.
public struct BlockContentPath: Codable, Hashable, Sendable {
  public enum Component: Codable, Hashable, Sendable {
    case block(Int)
    case listItem(Int)
    case albumImage(Int)
  }

  public var components: [Component]

  public init(_ components: [Component] = []) {
    self.components = components
  }

  fileprivate func appending(_ component: Component) -> Self {
    Self(components + [component])
  }
}

public enum BlockContentNodeKind: Hashable, Sendable {
  case math
  case paragraph
  case heading
  case code
  case list
  case listItem
  case separator
  case image
  case album
  case disclosure
  case footer
  case quote
  case table
}

public struct BlockContentReconciliation: Equatable, Sendable {
  public struct PhotoMove: Equatable, Sendable {
    public var photoID: Int64
    public var from: BlockContentPath
    public var to: BlockContentPath
  }

  public var reusablePaths: Set<BlockContentPath>
  public var insertedPaths: Set<BlockContentPath>
  public var removedPaths: Set<BlockContentPath>
  public var photoMoves: [PhotoMove]
}

public enum BlockContentReconciler {
  public static func reconcile(
    previous: InlineProtocol.BlockContent?,
    current: InlineProtocol.BlockContent
  ) -> BlockContentReconciliation {
    let previousNodes = flatten(previous?.blocks ?? [])
    let currentNodes = flatten(current.blocks)
    let previousByPath = Dictionary(uniqueKeysWithValues: previousNodes.map { ($0.path, $0) })
    let currentByPath = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.path, $0) })

    let reusable = Set(currentNodes.compactMap { node in
      previousByPath[node.path]?.kind == node.kind ? node.path : nil
    })
    let inserted = Set(currentByPath.keys).subtracting(reusable)
    let removed = Set(previousByPath.keys).subtracting(reusable)

    let previousPhotos = uniquePhotoPaths(in: previousNodes)
    let currentPhotos = uniquePhotoPaths(in: currentNodes)
    let moves = currentPhotos.compactMap { photoID, currentPath -> BlockContentReconciliation.PhotoMove? in
      guard let previousPath = previousPhotos[photoID], previousPath != currentPath else { return nil }
      return .init(photoID: photoID, from: previousPath, to: currentPath)
    }.sorted { lhs, rhs in lhs.photoID < rhs.photoID }

    return .init(
      reusablePaths: reusable,
      insertedPaths: inserted,
      removedPaths: removed,
      photoMoves: moves
    )
  }

  private struct Node {
    var path: BlockContentPath
    var kind: BlockContentNodeKind
    var photoID: Int64?
  }

  private static func flatten(
    _ blocks: [InlineProtocol.Block],
    parent: BlockContentPath = .init()
  ) -> [Node] {
    blocks.enumerated().flatMap { index, block -> [Node] in
      let path = parent.appending(.block(index))
      guard let kind = block.kind else { return [] }

      switch kind {
      case .math:
        return [Node(path: path, kind: .math)]
      case .paragraph:
        return [Node(path: path, kind: .paragraph)]
      case .heading:
        return [Node(path: path, kind: .heading)]
      case .code:
        return [Node(path: path, kind: .code)]
      case let .list(list):
        let children = list.items.enumerated().flatMap { itemIndex, item in
          let itemPath = path.appending(.listItem(itemIndex))
          return [Node(path: itemPath, kind: .listItem)] + flatten(item.children, parent: itemPath)
        }
        return [Node(path: path, kind: .list)] + children
      case .separator:
        return [Node(path: path, kind: .separator)]
      case let .image(image):
        return [Node(path: path, kind: .image, photoID: readyPhotoID(image))]
      case let .album(album):
        let images = album.images.enumerated().map { imageIndex, image in
          Node(
            path: path.appending(.albumImage(imageIndex)),
            kind: .image,
            photoID: readyPhotoID(image)
          )
        }
        return [Node(path: path, kind: .album)] + images
      case let .disclosure(disclosure):
        return [Node(path: path, kind: .disclosure)] + flatten(disclosure.children, parent: path)
      case .footer:
        return [Node(path: path, kind: .footer)]
      case let .quote(quote):
        return [Node(path: path, kind: .quote)] + flatten(quote.children, parent: path)
      case .table:
        return [Node(path: path, kind: .table)]
      }
    }
  }

  private static func readyPhotoID(_ image: InlineProtocol.BlockImage) -> Int64? {
    guard case let .ready(photo)? = image.state, photo.id > 0 else { return nil }
    return photo.id
  }

  private static func uniquePhotoPaths(in nodes: [Node]) -> [Int64: BlockContentPath] {
    let grouped = Dictionary(grouping: nodes.compactMap { node in
      node.photoID.map { ($0, node.path) }
    }, by: { $0.0 })
    return grouped.compactMapValues { entries in
      entries.count == 1 ? entries[0].1 : nil
    }
  }
}
