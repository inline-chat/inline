import CoreGraphics
import Foundation

/// The complete geometry-affecting environment known to the list. Applications
/// increment environmentRevision when fonts, layout policy, or cell inputs
/// outside the item revision change. The package never reads app settings.
public struct ChatListLayoutContext: Equatable, Sendable {
  public var width: CGFloat
  public var displayScale: CGFloat
  public var environmentRevision: UInt64

  public init(width: CGFloat, displayScale: CGFloat = 1, environmentRevision: UInt64 = 0) {
    self.width = width
    self.displayScale = displayScale
    self.environmentRevision = environmentRevision
  }
}

/// An immutable cell payload and its exact prepared geometry. IDs identify row
/// occurrences; a parent preview and a message must have different IDs even if
/// they refer to the same application message. Content may be any cell plan.
public struct ChatListItem<ID: Hashable & Sendable, Content> {
  public let id: ID
  public let revision: UInt64
  public let reuseIdentifier: String
  public let content: Content
  public let height: CGFloat
  public let elements: [String: CGRect]
  public let canAnchor: Bool

  public init(
    id: ID, revision: UInt64, reuseIdentifier: String = "cell", content: Content,
    height: CGFloat, elements: [String: CGRect] = [:], canAnchor: Bool = true
  ) {
    self.id = id
    self.revision = revision
    self.reuseIdentifier = reuseIdentifier
    self.content = content
    self.height = height
    self.elements = elements
    self.canAnchor = canAnchor
  }

  public var geometry: TimelineRow<ID> {
    .init(id: id, height: height, elements: elements, canAnchor: canAnchor)
  }
}

extension ChatListItem: Sendable where Content: Sendable {}

public enum ChatListEdge: Equatable, Sendable { case older, newer }

public struct ChatListHistoryAvailability: Equatable, Sendable {
  public var hasOlder: Bool
  public var hasNewer: Bool
  /// The adapter certifies that this window reaches the actual live end.
  public var isAtLiveEnd: Bool

  public init(hasOlder: Bool = false, hasNewer: Bool = false, isAtLiveEnd: Bool = true) {
    self.hasOlder = hasOlder
    self.hasNewer = hasNewer
    self.isAtLiveEnd = isAtLiveEnd
  }
}

public struct ChatListSnapshot<ID: Hashable & Sendable, Content> {
  public let context: ChatListLayoutContext
  public let items: [ChatListItem<ID, Content>]
  public let history: ChatListHistoryAvailability
  public let decorations: [ChatListDecoration<ID>]

  public init(
    context: ChatListLayoutContext, items: [ChatListItem<ID, Content>],
    history: ChatListHistoryAvailability = .init(), decorations: [ChatListDecoration<ID>] = []
  ) {
    self.context = context
    self.items = items
    self.history = history
    self.decorations = decorations
  }

  public func validate() throws {
    guard context.width.isFinite, context.width > 0,
          context.displayScale.isFinite, context.displayScale > 0 else { throw ChatListError.invalidContext }
    var ids = Set<ID>()
    for item in items {
      guard ids.insert(item.id).inserted else { throw ChatListError.duplicateIdentity }
      guard item.height.isFinite, item.height >= 0,
            item.elements.values.allSatisfy({
              $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite
                && $0.width >= 0 && $0.height >= 0
            }) else { throw ChatListError.invalidGeometry }
    }
  }
}

extension ChatListSnapshot: Sendable where Content: Sendable {}

public enum ChatListError: Error, Equatable {
  case invalidContext, invalidGeometry, duplicateIdentity, staleContext, reentrantTransaction, disposed
}

/// Who owns displacement when applying a changed viewport.
public enum ChatListViewportAdjustment: Equatable, Sendable {
  /// Keep the visible reading point attached to the changed inset edge.
  case preserveAnchor
  /// Native input already moved the content with this viewport change.
  /// Install insets immediately without adding another scroll displacement.
  /// Independent content changes still preserve their reading anchor.
  case nativeInput
}

public enum ChatListAnimation: Equatable, Sendable {
  case none
  /// The default system spring.
  case animated
  case motion(ChatListMotion)

  public var motion: ChatListMotion? {
    switch self {
      case .none: nil
      case .animated: .system
      case let .motion(motion): motion
    }
  }

  public var isAnimated: Bool { self != .none }
}

/// How a newly installed row enters. Telegram distinguishes an inserted message
/// (its apparent height grows) from loaded history that only appears.
public enum ChatListInsertion: Equatable, Sendable {
  /// Height grows from zero and the row fades in. Neighbors slide.
  case grow
  /// Height grows from zero with full opacity; the slot clips the content.
  case reveal
  /// Full height immediately; only opacity animates.
  case fade
  case none
}

/// How a removed row leaves. It stays resident until the motion settles.
public enum ChatListRemoval: Equatable, Sendable {
  /// Height collapses to zero and the row fades out. Neighbors close the gap.
  case collapse
  /// Height collapses with full opacity, for an effect drawn over the cell.
  case collapseOpaque
  case none
}

/// Per-transaction row transitions, matching Telegram's per-item insertion
/// and removal options. Rows not listed use the defaults.
public struct ChatListTransitions<ID: Hashable & Sendable>: Sendable {
  public var insertion: ChatListInsertion
  public var removal: ChatListRemoval
  public var insertions: [ID: ChatListInsertion]
  public var removals: [ID: ChatListRemoval]
  /// Surviving rows whose order changed slide from their previous positions.
  public var animatesMoves: Bool

  public init(
    insertion: ChatListInsertion = .grow, removal: ChatListRemoval = .collapse,
    insertions: [ID: ChatListInsertion] = [:], removals: [ID: ChatListRemoval] = [:],
    animatesMoves: Bool = false
  ) {
    self.insertion = insertion
    self.removal = removal
    self.insertions = insertions
    self.removals = removals
    self.animatesMoves = animatesMoves
  }

  func insertion(for id: ID) -> ChatListInsertion { insertions[id] ?? insertion }
  func removal(for id: ID) -> ChatListRemoval { removals[id] ?? removal }
}

/// Where a navigation places a row, as Telegram's `ListViewScrollPosition`.
public enum ChatListScrollPosition: Equatable, Sendable {
  /// Row top this far below the usable top edge.
  case top(CGFloat)
  /// Row bottom this far above the usable bottom edge.
  case bottom(CGFloat)
  /// Centered; a row taller than the usable height aligns its top instead.
  case center
  /// Scroll only as far as needed to reveal the whole row (or its top).
  case visible
}

/// Direction of a far jump. Content slides in from this side over at most one
/// screen instead of scrolling through everything in between.
public enum ChatListScrollDirection: Equatable, Sendable {
  /// Toward older rows: content moves down.
  case up
  /// Toward newer rows: content moves up.
  case down
}

public struct ChatListScrollRequest<ID: Hashable & Sendable>: Equatable, Sendable {
  public var id: ID
  public var position: ChatListScrollPosition
  public var direction: ChatListScrollDirection?

  public init(id: ID, position: ChatListScrollPosition = .center, direction: ChatListScrollDirection? = nil) {
    self.id = id
    self.position = position
    self.direction = direction
  }
}

/// Scroll lifecycle, as Telegram's list callbacks.
public enum ChatListScrollEvent: Equatable, Sendable {
  case userScrollBegan
  /// A drag lifted; deceleration may follow.
  case draggingEnded(willDecelerate: Bool)
  /// Native input and deceleration both ended.
  case userScrollEnded
  case directionChanged(ChatListScrollDirection)
  /// An explicit navigation reached its target.
  case navigationFinished
  /// A drag lifted more than 48 pt past the first or last row.
  case releasedPastEdge(ChatListEdge)
}

/// Distances to the content edges in the presented frame, plus how far content
/// moved on screen since the previous frame (Telegram's `addContentOffset`).
public struct ChatListContentOffset: Equatable, Sendable {
  public let fromTop: CGFloat
  public let fromBottom: CGFloat
  public let delta: CGFloat
}

/// A row's on-screen share inside the usable (unoccluded) viewport.
public enum ChatListRowVisibility: Equatable, Sendable {
  case hidden
  /// Visible fraction of the row and its rect in viewport coordinates.
  case visible(fraction: CGFloat, rect: CGRect)

  public var fraction: CGFloat {
    if case let .visible(fraction, _) = self { return fraction }
    return 0
  }
}

/// Rows inside the usable viewport, oldest first.
public struct ChatListVisibleRange<ID: Hashable & Sendable>: Equatable, Sendable {
  public let ids: [ID]
  public let fullyVisible: [ID]
  public var first: ID? { ids.first }
  public var last: ID? { ids.last }
}

/// A removed row about to animate out, with its presented frame.
public struct ChatListRemovalEvent<ID: Hashable & Sendable>: Sendable {
  public let id: ID
  /// Frame in viewport coordinates at the moment of removal.
  public let frame: CGRect
  public let removal: ChatListRemoval
}

/// A finished reorder. `before`/`after` are the new neighbors among all rows.
public struct ChatListReorder<ID: Hashable & Sendable>: Equatable, Sendable {
  public let id: ID
  public let fromIndex: Int
  public let toIndex: Int
  public let before: ID?
  public let after: ID?
}

public struct ChatListConfiguration: Sendable {
  public var overscan: CGFloat
  public var maximumReusableCellsPerKind: Int
  public var historyTriggerDistance: CGFloat
  public var usesAutomaticDisplayClock: Bool

  public init(
    overscan: CGFloat = 500, maximumReusableCellsPerKind: Int = 12,
    historyTriggerDistance: CGFloat = 240, usesAutomaticDisplayClock: Bool = true
  ) {
    self.overscan = overscan.isFinite ? max(0, overscan) : 500
    self.maximumReusableCellsPerKind = max(0, maximumReusableCellsPerKind)
    self.historyTriggerDistance = historyTriggerDistance.isFinite ? max(0, historyTriggerDistance) : 240
    self.usesAutomaticDisplayClock = usesAutomaticDisplayClock
  }
}

/// A cell-owned semantic address. The package never inspects its token. Capture
/// is performed before replacing the installed snapshot, using visible cell
/// coordinates; resolution validates correspondence against the replacement.
public struct ChatListCellAnchor {
  public let token: AnyHashable
  public let localY: CGFloat

  public init(token: AnyHashable, localY: CGFloat) {
    self.token = token
    self.localY = localY
  }
}

/// Resolve once against prepared geometry. Per-frame anchoring then follows
/// the named child's animated frame without calling back into cell layout.
public struct ChatListAnchorLocation: Equatable, Sendable {
  public let element: String?
  public let offsetY: CGFloat

  public init(element: String? = nil, offsetY: CGFloat) {
    self.element = element
    self.offsetY = offsetY
  }

  public func localY(in elements: [String: CGRect]) -> CGFloat? {
    guard offsetY.isFinite else { return nil }
    guard let element else { return offsetY }
    return elements[element].map { $0.minY + offsetY }
  }
}

public struct ChatListPresentationEvent<ID: Hashable & Sendable>: Sendable {
  public let generation: UInt64
  public let layout: TimelineLayout<ID>
  public let intent: TimelineIntent<ID>
  public let isUserScrolling: Bool
}
