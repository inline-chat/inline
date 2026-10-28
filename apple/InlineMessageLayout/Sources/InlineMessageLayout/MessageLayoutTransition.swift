import CoreGraphics

/// How an update moves. One value drives every node and the row height together.
public enum MessageMotion: Hashable, Sendable {
  case immediate
  case easeInOut(duration: Double)
  /// Critically damped when `bounce` is 0, matching UIKit's duration/bounce springs.
  case spring(duration: Double, bounce: Double)

  /// Content changes: edits, reactions, footer moves. Telegram iOS's message spring: critically
  /// damped, stiffness 555 at mass 1, which is a 0.27 s response.
  public static let standard = MessageMotion.spring(duration: 0.27, bounce: 0)
  /// One more revealed line while a message streams.
  public static let streamingLine = MessageMotion.easeInOut(duration: 0.15)

  public func resolved(reduceMotion: Bool) -> MessageMotion {
    reduceMotion ? .immediate : self
  }

  public var duration: Double {
    switch self {
    case .immediate: 0
    case let .easeInOut(duration): duration
    case let .spring(duration, _): duration
    }
  }
}

/// What changes between two layouts of the same message, keyed by node.
///
/// The host applies `to` frames inside one animation; inserted nodes fade and scale in at their
/// final frame, removed nodes fade out from their old frame.
public struct MessageLayoutTransition: Sendable {
  public enum Change: Hashable, Sendable {
    case moved(from: CGRect, to: CGRect)
    case inserted(CGRect)
    case removed(CGRect)
  }

  public let changes: [MessageLayoutNode: Change]
  public let fromSize: CGSize
  public let toSize: CGSize
  public let fromBubble: MessageLayout.Bubble?
  public let toBubble: MessageLayout.Bubble
  /// Nodes whose visibility flips between drawn and reserved.
  public let shown: Set<MessageLayoutNode>
  public let hidden: Set<MessageLayoutNode>

  public init(from old: MessageLayout?, to new: MessageLayout) {
    var changes: [MessageLayoutNode: Change] = [:]
    let oldFrames = old?.frames ?? [:]
    for (node, frame) in new.frames {
      if let previous = oldFrames[node] {
        if previous != frame {
          changes[node] = .moved(from: previous, to: frame)
        }
      } else {
        changes[node] = .inserted(frame)
      }
    }
    for (node, frame) in oldFrames where new.frames[node] == nil {
      changes[node] = .removed(frame)
    }
    self.changes = changes
    fromSize = old?.size ?? new.size
    toSize = new.size
    fromBubble = old?.bubble
    toBubble = new.bubble
    let oldHidden = old?.hiddenNodes ?? []
    shown = oldHidden.subtracting(new.hiddenNodes)
    hidden = new.hiddenNodes.subtracting(oldHidden)
  }

  public var changesHeight: Bool { fromSize.height != toSize.height }

  public var isEmpty: Bool {
    changes.isEmpty && fromSize == toSize && fromBubble == toBubble && shown.isEmpty && hidden.isEmpty
  }
}
