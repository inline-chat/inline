import ContextMenuAccessoryStructs
import UIKit

enum ContextMenuAccessoryLocation: UInt {
  case above = 0
  case below = 1
  case leading = 2
  case trailing = 3
}

enum ContextMenuAccessoryTrackingAxis: UInt {
  case none = 0
  case horizontal = 1
  case vertical = 2
}

enum ContextMenuAccessoryAttachment: UInt64 {
  case leading = 0
  case center = 1
  case trailing = 2
}

enum ContextMenuAccessoryAlignment: UInt64 {
  case center = 1
  case leading = 2
  case trailing = 8
}

struct ContextMenuAccessoryConfiguration {
  let location: ContextMenuAccessoryLocation
  let trackingAxis: ContextMenuAccessoryTrackingAxis
  let anchor: ContextMenuAccessoryAnchor

  init(
    location: ContextMenuAccessoryLocation,
    trackingAxis: ContextMenuAccessoryTrackingAxis,
    attachment: ContextMenuAccessoryAttachment = .center,
    alignment: ContextMenuAccessoryAlignment = .center,
    attachmentOffset: Double = 0,
    alignmentOffset: Double = 0,
    gravity: Int64 = 0
  ) {
    self.location = location
    self.trackingAxis = trackingAxis
    self.anchor = ContextMenuAccessoryAnchor(
      attachment: attachment.rawValue,
      alignment: alignment.rawValue,
      attachmentOffset: attachmentOffset,
      alignmentOffset: alignmentOffset,
      gravity: gravity
    )
  }
}

protocol AnyContextMenuIdentifierUIView: UIView, AnyObject {
  var accessoryView: UIView { get }
  var configuration: ContextMenuAccessoryConfiguration { get }
  var interaction: UIContextMenuInteraction? { get set }
}

class ContextMenuIdentifierUIView: UIView, AnyContextMenuIdentifierUIView, NSCopying {
  let accessoryView: UIView
  let configuration: ContextMenuAccessoryConfiguration
  weak var interaction: UIContextMenuInteraction?

  init(accessoryView: UIView, configuration: ContextMenuAccessoryConfiguration) {
    self.accessoryView = accessoryView
    self.configuration = configuration
    super.init(frame: .zero)

    isHidden = true
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func copy(with zone: NSZone? = nil) -> Any {
    return self
  }
}
