import Foundation
import InlineProtocol

/// A local structural path. It deliberately never crosses the protocol or
/// database boundary. Paths identify positions within one snapshot, not nodes
/// across edits; use reconciliation before carrying view or interaction state.
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

  /// Current path -> previous path. Apply this simultaneously, never in place:
  /// moves may swap positions or target a position occupied by a removed node.
  public var previousPathByCurrentPath: [BlockContentPath: BlockContentPath]
  public var reusablePaths: Set<BlockContentPath>
  public var insertedPaths: Set<BlockContentPath>
  public var removedPaths: Set<BlockContentPath>
  public var photoMoves: [PhotoMove]
}

public enum BlockContentReconciler {
  public static func reconcile(
    previous: InlineProtocol.BlockContent?,
    current: InlineProtocol.BlockContent,
    previousSource: String? = nil,
    currentSource: String? = nil
  ) -> BlockContentReconciliation {
    let previousNodes = flatten(previous?.blocks ?? [], source: previousSource.map { $0 as NSString })
    let currentNodes = flatten(current.blocks, source: currentSource.map { $0 as NSString })
    let previousByPath = Dictionary(uniqueKeysWithValues: previousNodes.map { ($0.path, $0) })
    let currentByPath = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.path, $0) })
    let sameSnapshot = previous == current && sourcesEqual(previousSource, currentSource)

    // Resolve semantic matches before positional reuse so a newly inserted node
    // cannot take the view belonging to a moved node. Duplicate anchors never
    // choose an arbitrary occurrence, even when one happens to share a path.
    let previousUnique = uniqueIdentityPaths(in: previousNodes)
    let currentUnique = uniqueIdentityPaths(in: currentNodes)
    var sources: [BlockContentPath: BlockContentPath] = [:]
    if sameSnapshot {
      for node in currentNodes { sources[node.path] = node.path }
    } else {
      for (identity, path) in currentUnique {
        guard let oldPath = previousUnique[identity],
              let old = previousByPath[oldPath], let new = currentByPath[path],
              compatibleMedia(old, new)
        else { continue }
        sources[path] = oldPath
      }
      let usedPaths = Set(sources.values)
      for node in currentNodes where sources[node.path] == nil && !usedPaths.contains(node.path) {
        guard !node.requiresIdentity, previousByPath[node.path]?.kind == node.kind else { continue }
        sources[node.path] = node.path
      }
    }
    let reusable = Set(sources.compactMap { $0.key == $0.value ? $0.key : nil })
    let inserted = Set(currentByPath.keys).subtracting(sources.keys)
    let removed = Set(previousByPath.keys).subtracting(sources.values)
    let moves = sources.compactMap { path, oldPath -> BlockContentReconciliation.PhotoMove? in
      guard path != oldPath, let photoID = currentByPath[path]?.photoID else { return nil }
      return .init(photoID: photoID, from: oldPath, to: path)
    }.sorted { $0.photoID < $1.photoID }

    return .init(
      previousPathByCurrentPath: sources,
      reusablePaths: reusable,
      insertedPaths: inserted,
      removedPaths: removed,
      photoMoves: moves
    )
  }

  private static func sourcesEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (lhs?, rhs?): lhs.utf8.elementsEqual(rhs.utf8)
    default: false
    }
  }

  fileprivate static func sourceHash(_ source: String) -> Int {
    // String.hashValue normalizes Unicode. Range-bearing snapshots need literal
    // bytes, because canonically equivalent strings can have different offsets.
    var source = source
    return source.withUTF8 { bytes in
      var hasher = Hasher()
      hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
      return hasher.finalize()
    }
  }

  fileprivate enum Identity: Hashable, Sendable {
    case disclosure(kind: Int, summary: String)
    case table(header: [String], alignments: [Int], isRTL: Bool)
    case album(firstPhotoID: Int64)
    case photo(Int64)
  }

  fileprivate static func disclosureIdentities(
    content: InlineProtocol.BlockContent,
    source: String
  ) -> [BlockContentPath: Identity] {
    Dictionary(uniqueKeysWithValues: flatten(content.blocks, source: source as NSString).compactMap { node in
      guard node.kind == .disclosure, let identity = node.identity else { return nil }
      return (node.path, identity)
    })
  }

  private struct Node {
    var path: BlockContentPath
    var kind: BlockContentNodeKind
    var photoID: Int64?
    var identity: Identity?
    var albumPhotoIDs: [Int64] = []

    var requiresIdentity: Bool {
      switch kind {
      case .disclosure, .table, .album, .image: true
      default: false
      }
    }
  }

  private static func flatten(
    _ blocks: [InlineProtocol.Block],
    source: NSString?,
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
          return [Node(path: itemPath, kind: .listItem)] + flatten(item.children, source: source, parent: itemPath)
        }
        return [Node(path: path, kind: .list)] + children
      case .separator:
        return [Node(path: path, kind: .separator)]
      case let .image(image):
        return [imageNode(image, path: path)]
      case let .album(album):
        let images = album.images.enumerated().map { imageIndex, image in
          imageNode(image, path: path.appending(.albumImage(imageIndex)))
        }
        let ids = images.compactMap(\.photoID)
        let identity: Identity? = ids.count == images.count ? ids.first.map { .album(firstPhotoID: $0) } : nil
        return [Node(path: path, kind: .album, identity: identity, albumPhotoIDs: ids)] + images
      case let .disclosure(disclosure):
        let identity = text(disclosure.summary, in: source).flatMap { summary -> Identity? in
          guard !summary.isEmpty else { return nil }
          return .disclosure(kind: disclosure.kind.rawValue, summary: summary)
        }
        return [Node(path: path, kind: .disclosure, identity: identity)]
          + flatten(disclosure.children, source: source, parent: path)
      case .footer:
        return [Node(path: path, kind: .footer)]
      case let .quote(quote):
        return [Node(path: path, kind: .quote)] + flatten(quote.children, source: source, parent: path)
      case let .table(table):
        let cells = table.rows.first?.cells ?? []
        let header = cells.compactMap { text($0, in: source) }
        let identity: Identity? = !cells.isEmpty && header.count == cells.count
          ? .table(header: header, alignments: table.alignments.map(\.rawValue), isRTL: table.isRtl) : nil
        return [Node(path: path, kind: .table, identity: identity)]
      }
    }
  }

  private static func readyPhotoID(_ image: InlineProtocol.BlockImage) -> Int64? {
    guard case let .ready(photo)? = image.state, photo.id > 0 else { return nil }
    return photo.id
  }

  private static func imageNode(_ image: InlineProtocol.BlockImage, path: BlockContentPath) -> Node {
    let id = readyPhotoID(image)
    return Node(path: path, kind: .image, photoID: id, identity: id.map { .photo($0) })
  }

  private static func uniqueIdentityPaths(in nodes: [Node]) -> [Identity: BlockContentPath] {
    let grouped = Dictionary(grouping: nodes.compactMap { node in
      node.identity.map { ($0, node.path) }
    }, by: { $0.0 })
    return grouped.compactMapValues { entries in
      entries.count == 1 ? entries[0].1 : nil
    }
  }

  private static func compatibleMedia(_ previous: Node, _ current: Node) -> Bool {
    guard current.kind == .album else { return true }
    // Appending to an album may retain its viewport; reordering/replacing its
    // existing photos must not. Pending photos have no trustworthy wire identity.
    return zip(previous.albumPhotoIDs, current.albumPhotoIDs).allSatisfy { $0 == $1 }
  }

  private static func text(_ range: InlineProtocol.BlockText, in source: NSString?) -> String? {
    guard let source, range.offset >= 0, range.length >= 0,
          range.offset <= Int64(source.length), range.length <= Int64(source.length) - range.offset
    else { return nil }
    let start = Int(range.offset), end = start + Int(range.length)
    func splitsSurrogate(_ boundary: Int) -> Bool {
      boundary > 0 && boundary < source.length
        && (0xD800...0xDBFF).contains(source.character(at: boundary - 1))
        && (0xDC00...0xDFFF).contains(source.character(at: boundary))
    }
    guard !splitsSurrogate(start), !splitsSurrogate(end) else { return nil }
    return source.substring(with: NSRange(location: start, length: end - start))
  }
}

/// Shared by the existing view/state owners. Visible persisted rows keep their
/// database ID when confirmation clears randomId and replaces messageId.
/// Unsaved values fall back to namespaced random/server IDs, scoped to the chat.
public struct BlockContentMessageIdentity: Hashable, Sendable {
  private enum ID: Hashable, Sendable {
    case random(Int64)
    case global(Int64)
    case message(Int64)
  }

  private let chatID: Int64
  private let id: ID

  public init(message: Message) {
    chatID = message.chatId
    if let globalID = message.globalId, globalID != 0 {
      id = .global(globalID)
    } else if let randomID = message.randomId, randomID != 0 {
      id = .random(randomID)
    } else {
      id = .message(message.messageId)
    }
  }
}

/// Value state held by the existing per-message platform stores. Only snapshots
/// where the user toggled a disclosure are retained. No source text or full
/// protobuf is kept: the revision key uses the model's existing cached signature.
public struct BlockContentDisclosureState: Sendable {
  private struct Revision: Equatable, Sendable {
    var contentSignature: Int
    var byteCount: Int
    var sourceHash: Int
  }

  private var revision: Revision?
  private var identities: [BlockContentPath: BlockContentReconciler.Identity] = [:]
  private var values: [BlockContentPath: Bool] = [:]

  public init() {}

  public mutating func overrides(content: BlockContentPayload?, source: String) -> [BlockContentPath: Bool] {
    guard let content else {
      self = Self()
      return [:]
    }
    let nextRevision = Revision(
      contentSignature: content.cacheSignature, byteCount: content.byteCount, sourceHash: BlockContentReconciler.sourceHash(source)
    )
    guard revision != nextRevision else { return values }
    let next = BlockContentReconciler.disclosureIdentities(content: content.content, source: source)
    let oldGroups = Dictionary(grouping: identities, by: { $0.value })
    let newGroups = Dictionary(grouping: next, by: { $0.value })
    var mapped: [BlockContentPath: Bool] = [:]
    for (path, value) in values {
      guard let identity = identities[path], oldGroups[identity]?.count == 1,
            let targets = newGroups[identity], targets.count == 1
      else { continue }
      mapped[targets[0].key] = value
    }
    identities = next
    values = mapped
    revision = nextRevision
    return values
  }

  public mutating func set(
    _ expanded: Bool, path: BlockContentPath, content: BlockContentPayload?, source: String
  ) {
    _ = overrides(content: content, source: source)
    guard identities[path] != nil else { return }
    values[path] = expanded
  }
}
