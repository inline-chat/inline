/// Classifies observations made after an AppKit collection update completes.
/// Direct subviews are a diagnostic sample, not a collection-view ownership API.
public enum SidebarCollectionSceneAudit {
  public struct Root<ID: Hashable> {
    public let id: ID
    public let isAttachedInViewport: Bool
    public let hasActiveAnimation: Bool
    public let rendererChildCount: Int
    public let nativeContentChildCount: Int?

    public init(
      id: ID,
      isAttachedInViewport: Bool,
      hasActiveAnimation: Bool,
      rendererChildCount: Int,
      nativeContentChildCount: Int? = nil
    ) {
      self.id = id
      self.isAttachedInViewport = isAttachedInViewport
      self.hasActiveAnimation = hasActiveAnimation
      self.rendererChildCount = rendererChildCount
      self.nativeContentChildCount = nativeContentChildCount
    }
  }

  public struct Result<ID: Hashable> {
    public let unownedAttachedIDs: Set<ID>
    public let animatingUnownedIDs: Set<ID>
    public let unexpectedRendererIDs: Set<ID>
    public var hasAnomaly: Bool {
      !unownedAttachedIDs.isEmpty || !unexpectedRendererIDs.isEmpty
    }
  }

  public static func inspect<ID: Hashable>(
    ownedVisibleRootIDs: Set<ID>,
    attachedRoots: [Root<ID>]
  ) -> Result<ID> {
    var unownedAttachedIDs = Set<ID>()
    var animatingUnownedIDs = Set<ID>()
    var unexpectedRendererIDs = Set<ID>()

    for root in attachedRoots where root.isAttachedInViewport {
      if ownedVisibleRootIDs.contains(root.id) {
        if root.rendererChildCount != 1
          || root.nativeContentChildCount.map({ $0 != 1 }) == true {
          unexpectedRendererIDs.insert(root.id)
        }
      } else {
        unownedAttachedIDs.insert(root.id)
        if root.hasActiveAnimation {
          animatingUnownedIDs.insert(root.id)
        }
      }
    }

    return Result(
      unownedAttachedIDs: unownedAttachedIDs,
      animatingUnownedIDs: animatingUnownedIDs,
      unexpectedRendererIDs: unexpectedRendererIDs
    )
  }
}

/// A compact record of AppKit's documented item-display callbacks. The
/// collection view remains the source of truth for which items it owns.
public struct SidebarCollectionLifecycleLedger<ID: Hashable, Position: Hashable> {
  public enum EventKind: Equatable {
    case willDisplay
    case didEndDisplaying
  }

  public struct Event: Equatable {
    public let id: ID
    public let position: Position
    public let kind: EventKind
    public let sequence: Int
  }

  public struct Display: Equatable {
    public let position: Position
    public let willDisplaySequence: Int
  }

  private static var eventCapacity: Int { 128 }
  public private(set) var sequence = 0
  public private(set) var displayed: [ID: Display] = [:]
  private var recentEvents: [Event] = []
  private var nextEventSlot = 0

  public init() {}

  public mutating func willDisplay(_ id: ID, at position: Position) {
    sequence += 1
    displayed[id] = Display(position: position, willDisplaySequence: sequence)
    record(Event(id: id, position: position, kind: .willDisplay, sequence: sequence))
  }

  public mutating func didEndDisplaying(_ id: ID, at position: Position) {
    sequence += 1
    if displayed[id]?.position == position {
      displayed.removeValue(forKey: id)
    }
    record(Event(id: id, position: position, kind: .didEndDisplaying, sequence: sequence))
  }

  public func lastEvent(for id: ID) -> Event? {
    guard !recentEvents.isEmpty else { return nil }
    for offset in 0..<recentEvents.count {
      let index = (nextEventSlot - 1 - offset + Self.eventCapacity)
        % Self.eventCapacity
      let event = recentEvents[index]
      if event.id == id { return event }
    }
    return nil
  }

  private mutating func record(_ event: Event) {
    if recentEvents.count < Self.eventCapacity {
      recentEvents.append(event)
    } else {
      recentEvents[nextEventSlot] = event
    }
    nextEventSlot = (nextEventSlot + 1) % Self.eventCapacity
  }
}
